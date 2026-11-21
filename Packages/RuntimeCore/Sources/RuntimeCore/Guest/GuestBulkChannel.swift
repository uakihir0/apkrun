import CryptoKit
import Foundation
import GuestProtocol

/// One finished inbound transfer, keyed by its transfer ID.
public struct GuestInboundTransfer: Sendable, Equatable {
    /// The announced transfer ID.
    public let transferID: UInt64
    /// The transfer kind of its `BulkBegin` (`BULK_KIND_*`).
    public let kind: GPBulkKind
    /// The announced name and MIME type, if any.
    public let name: String
    /// The MIME type of the payload.
    public let mimeType: String
    /// The whole payload when it fit in memory, nil when the transfer was
    /// spooled to `fileURL` (kind `.file`, guest-protocol.md §10).
    public let bytes: Data?
    /// The spool file of a `.file` transfer (under
    /// `~/Library/Caches/io.apkrun.APKRun/transfers/`); nil for in-memory
    /// payloads. The caller takes ownership of the file.
    public let fileURL: URL?
    /// The SHA-256 announced in `BulkEnd`, for the caller to verify a
    /// file-backed payload.
    public let sha256: Data?

    /// Creates an inbound transfer.
    public init(
        transferID: UInt64,
        kind: GPBulkKind,
        name: String,
        mimeType: String,
        bytes: Data?,
        fileURL: URL? = nil,
        sha256: Data? = nil
    ) {
        self.transferID = transferID
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.bytes = bytes
        self.fileURL = fileURL
        self.sha256 = sha256
    }
}

/// A persistent `.guestBulk` connection to one Guest Agent session
/// (guest-protocol.md §10). The agent announces transfers on the control
/// channel and pushes their frames here; the host announces its own
/// transfers (even IDs) the same way and sends the frames through
/// ``send(payload:kind:mimeType:)``.
///
/// The connection lives for one agent session token: a reconnecting agent
/// closes its secondary connections, so the caller drops the channel when
/// the session it was built for ends.
public actor GuestBulkChannel {
    /// One inbound transfer under reassembly. `file` transfers stream to a
    /// spool file (§10: receivers write to a temporary file) — the channel
    /// never holds a 2 GiB payload in memory.
    private struct Assembly {
        var kind: GPBulkKind
        var name: String
        var mimeType: String
        var bytes: Data
        /// Spool file for `.file` transfers.
        var fileURL: URL?
        var fileHandle: FileHandle?
        var written: Int64 = 0

        mutating func append(_ chunk: Data, cap: Int) -> Bool {
            if let handle = fileHandle {
                do {
                    try handle.write(contentsOf: chunk)
                    written += Int64(chunk.count)
                    return written <= 2 * 1024 * 1024 * 1024
                } catch {
                    return false
                }
            }
            bytes.append(chunk)
            return bytes.count <= cap
        }

        mutating func finish() -> (Data?, URL?) {
            try? fileHandle?.close()
            fileHandle = nil
            if fileURL != nil {
                return (nil, fileURL)
            }
            return (bytes, nil)
        }
    }

    /// The default per-transfer cap, 16 MiB like the diagnostics items.
    public static let defaultCap = 16 * 1024 * 1024
    /// A bulk chunk is at most 1 MiB (bulk.proto).
    private static let chunkSize = 1024 * 1024
    /// Completed inbound payloads are kept for 60 s against late fetchers.
    private static let retention: Duration = .seconds(60)

    private let agent: DevelopmentGuestAgent
    private let token: Data
    private let cap: Int

    private var connection: GuestConnection?
    private var consumer: Task<Void, Never>?
    private var requestsConsumer: Task<Void, Never>?
    /// Agent → host file requests (guest-protocol.md §7.5), one entry per
    /// request. Consumed by the host dispatcher.
    private let agentRequestsStream: AsyncStream<(id: UInt64, request: GPRequest)>
    private let agentRequestsContinuation:
        AsyncStream<
            (id: UInt64, request: GPRequest)
        >.Continuation
    private var assemblies: [UInt64: Assembly] = [:]
    /// Recently completed inbound payloads, pruned to 16 entries.
    private var completed: [(id: UInt64, at: ContinuousClock.Instant, transfer: GuestInboundTransfer)] =
        []
    /// Fetchers waiting on an announced transfer.
    private var waiters: [UInt64: [CheckedContinuation<GuestInboundTransfer?, Never>]] = [:]
    /// Host-allocated transfer IDs are even (bulk.proto).
    private var nextTransferID: UInt64 = 2

    /// Creates the channel to [agent]'s session, which `token` identifies.
    public init(
        agent: DevelopmentGuestAgent,
        token: Data,
        cap: Int = GuestBulkChannel.defaultCap
    ) {
        self.agent = agent
        self.token = token
        self.cap = cap
        let requests = AsyncStream.makeStream(
            of: (id: UInt64, request: GPRequest).self,
            bufferingPolicy: .bufferingNewest(64))
        agentRequestsStream = requests.stream
        agentRequestsContinuation = requests.continuation
    }

    /// Connects and starts the consumer. Idempotent: a connected channel is
    /// returned as is, a closed one is reopened.
    public func open() async throws(GuestProtocolFailure) {
        if let connection, await connection.isUsable { return }
        let connection = GuestConnection(
            endpoint: .guestBulk,
            transport: agent.transport,
            presentedToken: token,
            hostVersion: agent.hostVersion,
            logSink: agent.logSink
        )
        _ = try await connection.open()
        self.connection = connection
        consumer?.cancel()
        consumer = Task { [weak self] in
            for await frame in connection.bulkFrames {
                await self?.accept(frame)
            }
        }
        requestsConsumer?.cancel()
        requestsConsumer = Task { [weak self, connection] in
            for await request in connection.agentRequests {
                self?.agentRequestsContinuation.yield(request)
            }
        }
    }

    /// The agent → host file requests of guest-protocol.md §7.5, in order.
    /// The stream finishes when the channel closes.
    public nonisolated var agentRequests:
        AsyncStream<
            (id: UInt64, request: GPRequest)
        >
    {
        agentRequestsStream
    }

    /// Answers one agent request from ``agentRequests`` (§7.5). `result` is
    /// the response payload or an `.error`.
    public func respond(
        replyTo envelopeID: UInt64,
        result: GPResponse.OneOf_Result
    ) async throws(GuestProtocolFailure) {
        guard let connection else { throw .disconnected }
        try await connection.sendResponse(replyTo: envelopeID, result: result)
    }

    /// Closes the connection. A later ``open()`` reconnects.
    public func close() {
        consumer?.cancel()
        consumer = nil
        requestsConsumer?.cancel()
        requestsConsumer = nil
        for (_, var assembly) in assemblies {
            try? assembly.fileHandle?.close()
            if let url = assembly.fileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        assemblies.removeAll()
        for (_, waiter) in waiters {
            for continuation in waiter {
                continuation.resume(returning: nil)
            }
        }
        waiters.removeAll()
        let connection = connection
        self.connection = nil
        Task { await connection?.close() }
    }

    /// Sends `payload` as one transfer of `kind` and answers its
    /// host-allocated (even) transfer ID for the announcing request.
    public func send(
        payload: Data,
        kind: GPBulkKind,
        mimeType: String
    ) async throws(GuestProtocolFailure) -> UInt64 {
        try await open()
        guard let connection else { throw .disconnected }
        let transferID = nextTransferID
        nextTransferID += 2
        let digest = Data(SHA256.hash(data: payload))
        var begin = GPBulkBegin()
        begin.kind = kind
        begin.mimeType = mimeType
        begin.size = UInt64(payload.count)
        begin.sha256 = digest
        var frame = GPBulkFrame()
        frame.transferID = transferID
        frame.kind = .begin(begin)
        try await connection.sendBulkFrame(frame)
        var offset = 0
        while offset < payload.count {
            let end = min(offset + Self.chunkSize, payload.count)
            frame.kind = .chunk(payload[offset..<end])
            try await connection.sendBulkFrame(frame)
            offset = end
        }
        var tail = GPBulkEnd()
        tail.sha256 = digest
        frame.kind = .end(tail)
        try await connection.sendBulkFrame(frame)
        return transferID
    }

    /// Streams `file` as one transfer of `kind` without loading it in memory
    /// (desktop-integration.md §6.2: drops go up to 2 GiB). The announced
    /// name rides in `BulkBegin`.
    public func sendFile(
        _ file: FileHandle,
        size: Int64,
        name: String,
        kind: GPBulkKind,
        mimeType: String
    ) async throws(GuestProtocolFailure) -> UInt64 {
        try await open()
        guard let connection else { throw .disconnected }
        let transferID = nextTransferID
        nextTransferID += 2
        var hasher = SHA256()
        var begin = GPBulkBegin()
        begin.kind = kind
        begin.name = name
        begin.mimeType = mimeType
        begin.size = UInt64(clamping: size)
        var frame = GPBulkFrame()
        frame.transferID = transferID
        frame.kind = .begin(begin)
        do {
            try await connection.sendBulkFrame(frame)
            try file.seek(toOffset: 0)
            var sent: Int64 = 0
            while sent < size {
                let length = Int(min(Int64(Self.chunkSize), size - sent))
                let chunk: Data
                do {
                    guard let read = try file.read(upToCount: length), !read.isEmpty else {
                        throw GuestProtocolFailure.transferIOFailed(
                            detail: "read stopped at \(sent) of \(size) bytes")
                    }
                    chunk = read
                } catch let failure as GuestProtocolFailure {
                    throw failure
                } catch {
                    throw GuestProtocolFailure.transferIOFailed(detail: String(describing: error))
                }
                hasher.update(data: chunk)
                frame.kind = .chunk(chunk)
                try await connection.sendBulkFrame(frame)
                sent += Int64(chunk.count)
            }
            var tail = GPBulkEnd()
            tail.sha256 = Data(hasher.finalize())
            frame.kind = .end(tail)
            try await connection.sendBulkFrame(frame)
        } catch let failure as GuestProtocolFailure {
            var abort = GPBulkAbort()
            abort.reason = "send failed"
            frame.kind = .abort(abort)
            try? await connection.sendBulkFrame(frame)
            throw failure
        } catch {
            var abort = GPBulkAbort()
            abort.reason = "send failed"
            frame.kind = .abort(abort)
            try? await connection.sendBulkFrame(frame)
            throw GuestProtocolFailure.transferIOFailed(detail: String(describing: error))
        }
        return transferID
    }

    /// The payload of an announced inbound transfer. A completed transfer
    /// answers at once; an unfinished one is awaited up to `timeout`, and an
    /// aborted or timed-out one answers `nil`.
    public func transfer(
        _ transferID: UInt64,
        timeout: Duration = .seconds(10)
    ) async -> GuestInboundTransfer? {
        let now = ContinuousClock.now
        completed.removeAll { now - $0.at > Self.retention }
        if let index = completed.firstIndex(where: { $0.id == transferID }) {
            return completed.remove(at: index).transfer
        }
        let deadline = now.advanced(by: timeout)
        return await withTaskGroup(of: GuestInboundTransfer?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.addWaiter(transferID, deadline: deadline, continuation)
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            if result == nil {
                // The continuation ignores cancellation: evict the waiter so
                // it resumes and this group scope can actually exit.
                await self.evictWaiter(transferID)
            }
            return result ?? nil
        }
    }

    /// Registers a fetcher under `transferID` on this actor. A registration
    /// that lands past its own deadline — the losing arm of the fetch's task
    /// group — answers nil at once; a fresh fetch carries a fresh deadline
    /// and waits normally.
    private nonisolated func addWaiter(
        _ transferID: UInt64,
        deadline: ContinuousClock.Instant,
        _ continuation: CheckedContinuation<GuestInboundTransfer?, Never>
    ) {
        Task { await self.registerWaiter(transferID, deadline: deadline, continuation) }
    }

    private func registerWaiter(
        _ transferID: UInt64,
        deadline: ContinuousClock.Instant,
        _ continuation: CheckedContinuation<GuestInboundTransfer?, Never>
    ) {
        // A registration that lands after its fetch gave up — cancelled or
        // past its deadline — answers nil at once; a fresh fetch carries a
        // fresh deadline and waits normally.
        if Task.isCancelled || ContinuousClock.now >= deadline {
            continuation.resume(returning: nil)
        } else if let index = completed.firstIndex(where: { $0.id == transferID }) {
            continuation.resume(returning: completed.remove(at: index).transfer)
        } else {
            waiters[transferID, default: []].append(continuation)
        }
    }

    /// Answers every waiter of `transferID` with nil (a fetch timeout).
    private func evictWaiter(_ transferID: UInt64) {
        if let waiter = waiters.removeValue(forKey: transferID) {
            for continuation in waiter {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Feeds one received frame into the assemblies.
    private func accept(_ frame: GPBulkFrame) {
        switch frame.kind {
        case .begin(let begin):
            var assembly = Assembly(
                kind: begin.kind,
                name: begin.name,
                mimeType: begin.mimeType,
                bytes: Data()
            )
            if begin.kind == .file {
                let url = Self.spoolURL(frame.transferID)
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                if let handle = try? FileHandle(forWritingTo: url) {
                    assembly.fileURL = url
                    assembly.fileHandle = handle
                } else {
                    assembly.fileURL = url
                }
            }
            assemblies[frame.transferID] = assembly
        case .chunk(let chunk):
            guard var assembly = assemblies[frame.transferID] else { return }
            if !assembly.append(chunk, cap: cap) {
                try? assembly.fileHandle?.close()
                if let url = assembly.fileURL { try? FileManager.default.removeItem(at: url) }
                assemblies.removeValue(forKey: frame.transferID)
                Self.reply(.tooLarge, to: frame.transferID, via: connection)
            } else {
                assemblies[frame.transferID] = assembly
            }
        case .end(let end):
            guard var assembly = assemblies.removeValue(forKey: frame.transferID) else { return }
            let (bytes, fileURL) = assembly.finish()
            let transfer = GuestInboundTransfer(
                transferID: frame.transferID,
                kind: assembly.kind,
                name: assembly.name,
                mimeType: assembly.mimeType,
                bytes: bytes,
                fileURL: fileURL,
                sha256: end.sha256.isEmpty ? nil : end.sha256
            )
            Self.reply(.ok, to: frame.transferID, via: connection)
            if let waiter = waiters.removeValue(forKey: frame.transferID) {
                for continuation in waiter {
                    continuation.resume(returning: transfer)
                }
            } else {
                completed.append((frame.transferID, ContinuousClock.now, transfer))
                if completed.count > 16 {
                    completed.removeFirst()
                }
            }
        case .abort:
            if var assembly = assemblies.removeValue(forKey: frame.transferID) {
                try? assembly.fileHandle?.close()
                if let url = assembly.fileURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            if let waiter = waiters.removeValue(forKey: frame.transferID) {
                for continuation in waiter {
                    continuation.resume(returning: nil)
                }
            }
        default:
            break
        }
    }

    /// The spool file of an inbound `.file` transfer (guest-protocol.md §10).
    private static func spoolURL(_ transferID: UInt64) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("io.apkrun.APKRun/transfers", isDirectory: true)
            .appendingPathComponent("in-\(transferID)")
    }

    /// Sends the transfer ack the spec asks of receivers (guest-protocol.md §10).
    private static func reply(
        _ status: GPBulkAckStatus, to transferID: UInt64, via connection: GuestConnection?
    ) {
        guard let connection else { return }
        var ack = GPBulkAck()
        ack.status = status
        var frame = GPBulkFrame()
        frame.transferID = transferID
        frame.kind = .ack(ack)
        Task { try? await connection.sendBulkFrame(frame) }
    }
}
