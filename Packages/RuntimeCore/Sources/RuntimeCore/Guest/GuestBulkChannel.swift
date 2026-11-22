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
    /// The whole payload, at most the receiver's cap.
    public let bytes: Data

    /// Creates an inbound transfer.
    public init(
        transferID: UInt64,
        kind: GPBulkKind,
        name: String,
        mimeType: String,
        bytes: Data
    ) {
        self.transferID = transferID
        self.kind = kind
        self.name = name
        self.mimeType = mimeType
        self.bytes = bytes
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
    /// One inbound transfer under reassembly.
    private struct Assembly {
        var kind: GPBulkKind
        var name: String
        var mimeType: String
        var bytes: Data
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
    private var assemblies: [UInt64: Assembly] = [:]
    /// Recently completed inbound payloads, pruned to 16 entries.
    private var completed: [(id: UInt64, at: ContinuousClock.Instant, transfer: GuestInboundTransfer)] =
        []
    /// Fetchers waiting on an announced transfer, keyed by transfer id and
    /// tagged with the fetch token that registered them.
    private var waiters: [UInt64: [(
        token: UInt64,
        continuation: CheckedContinuation<GuestInboundTransfer?, Never>
    )]] = [:]
    /// Fetch tokens whose wait was settled before their waiter registration
    /// landed; a late registration answers nil instead of lingering forever.
    /// Tokens are unique per fetch, so a bounded FIFO keeps the newest 16.
    private var retiredFetches: [UInt64] = []
    private var nextFetchToken: UInt64 = 1
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
    }

    /// Closes the connection. A later ``open()`` reconnects.
    public func close() {
        consumer?.cancel()
        consumer = nil
        assemblies.removeAll()
        for (_, waiter) in waiters {
            for entry in waiter {
                entry.continuation.resume(returning: nil)
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
        let fetchToken = nextFetchToken
        nextFetchToken += 1
        return await withTaskGroup(of: GuestInboundTransfer?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.addWaiter(
                        transferID,
                        deadline: deadline,
                        token: fetchToken,
                        continuation
                    )
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
                await self.evictWaiter(transferID, token: fetchToken)
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
        token: UInt64,
        _ continuation: CheckedContinuation<GuestInboundTransfer?, Never>
    ) {
        Task {
            await self.registerWaiter(
                transferID,
                deadline: deadline,
                token: token,
                continuation
            )
        }
    }

    private func registerWaiter(
        _ transferID: UInt64,
        deadline: ContinuousClock.Instant,
        token: UInt64,
        _ continuation: CheckedContinuation<GuestInboundTransfer?, Never>
    ) {
        // A registration that lands after its own fetch gave up — cancelled
        // or past its deadline — answers nil at once; a different fetch still
        // waits normally under its own token.
        if Task.isCancelled || ContinuousClock.now >= deadline
            || retiredFetches.contains(token)
        {
            continuation.resume(returning: nil)
        } else if let index = completed.firstIndex(where: { $0.id == transferID }) {
            continuation.resume(returning: completed.remove(at: index).transfer)
        } else {
            waiters[transferID, default: []].append(
                (token: token, continuation: continuation)
            )
        }
    }

    /// Answers this fetch's waiters of `transferID` with nil (a fetch
    /// timeout) and refuses late registrations of the same fetch. Waiters of
    /// other concurrent fetches keep waiting.
    private func evictWaiter(_ transferID: UInt64, token: UInt64) {
        retiredFetches.append(token)
        if retiredFetches.count > 16 { retiredFetches.removeFirst() }
        guard var entries = waiters[transferID] else { return }
        var kept: [(token: UInt64, continuation: CheckedContinuation<GuestInboundTransfer?, Never>)] = []
        var dead: [CheckedContinuation<GuestInboundTransfer?, Never>] = []
        for entry in entries {
            if entry.token == token { dead.append(entry.continuation) } else { kept.append(entry) }
        }
        if kept.isEmpty {
            waiters.removeValue(forKey: transferID)
        } else {
            waiters[transferID] = kept
        }
        for continuation in dead {
            continuation.resume(returning: nil)
        }
    }

    /// Feeds one received frame into the assemblies.
    private func accept(_ frame: GPBulkFrame) {
        switch frame.kind {
        case .begin(let begin):
            assemblies[frame.transferID] = Assembly(
                kind: begin.kind,
                name: begin.name,
                mimeType: begin.mimeType,
                bytes: Data()
            )
        case .chunk(let chunk):
            guard var assembly = assemblies[frame.transferID] else { return }
            assembly.bytes.append(chunk)
            if assembly.bytes.count > cap {
                assemblies.removeValue(forKey: frame.transferID)
            } else {
                assemblies[frame.transferID] = assembly
            }
        case .end:
            guard let assembly = assemblies.removeValue(forKey: frame.transferID) else { return }
            let transfer = GuestInboundTransfer(
                transferID: frame.transferID,
                kind: assembly.kind,
                name: assembly.name,
                mimeType: assembly.mimeType,
                bytes: assembly.bytes
            )
            if let waiter = waiters.removeValue(forKey: frame.transferID) {
                for entry in waiter {
                    entry.continuation.resume(returning: transfer)
                }
            } else {
                completed.append((frame.transferID, ContinuousClock.now, transfer))
                if completed.count > 16 {
                    completed.removeFirst()
                }
            }
        case .abort:
            assemblies.removeValue(forKey: frame.transferID)
            if let waiter = waiters.removeValue(forKey: frame.transferID) {
                for entry in waiter {
                    entry.continuation.resume(returning: nil)
                }
            }
        default:
            break
        }
    }
}
