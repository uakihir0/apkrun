import Foundation
import GuestProtocol

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// The host sender for one Guest Agent bulk session (guest-protocol.md §10).
///
/// File data is read with `pread` in 1 MiB chunks, so the caller's file offset stays unchanged and neither the
/// complete file nor a backlog of chunks is held in memory.
actor GuestBulkChannel {
    /// The protocol's maximum size for one transfer.
    static let maximumTransferSize: UInt64 = 2_147_483_648
    /// The protocol's maximum chunk size.
    static let maximumChunkSize = 1_048_576
    /// Maximum time to wait for the receiver's acknowledgement after the final frame is written.
    static let defaultAcknowledgementTimeout: Duration = .seconds(300)

    private let connection: GuestConnection
    private let acknowledgementTimeout: Duration
    private var transferInFlight = false
    private var transferWaiters: [CheckedContinuation<Void, Never>] = []
    private var ackRelay: Task<Void, Never>?
    private var ackStreamEnded = false
    private var expectedAckTransferID: UInt64?
    private var receivedAck: GPBulkAck?
    private var ackContinuation: CheckedContinuation<Result<GPBulkAck, GuestAgentFailure>, Never>?
    private var ackTimeoutTask: Task<Void, Never>?

    /// Creates a sender over an already-open guest bulk connection.
    ///
    /// - Parameters:
    ///   - connection: A `.guestBulk` connection authenticated with the current control-session token.
    ///   - acknowledgementTimeout: A bounded wait for the receiver after a transfer completes.
    init(
        connection: GuestConnection,
        acknowledgementTimeout: Duration = GuestBulkChannel.defaultAcknowledgementTimeout
    ) {
        precondition(connection.endpoint == .guestBulk, "GuestBulkChannel requires the guest bulk endpoint")
        self.connection = connection
        self.acknowledgementTimeout = acknowledgementTimeout
    }

    /// Sends a regular file to the guest and waits for the matching `BulkAck`.
    ///
    /// The host allocates positive even transfer IDs. The supplied digest is sent in both `BulkBegin` and `BulkEnd`
    /// so the receiver can verify the exact bytes it wrote.
    func transferFile(
        _ fileHandle: FileHandle,
        transferID: UInt64,
        name: String,
        mimeType: String,
        size: UInt64,
        sha256: Data
    ) async throws(GuestAgentFailure) {
        await acquireTransfer()
        defer { releaseTransfer() }

        guard !Task.isCancelled else {
            throw Self.operationFailure("cancelled")
        }
        guard transferID > 0, transferID.isMultiple(of: 2),
            size <= Self.maximumTransferSize,
            sha256.count == 32,
            !name.isEmpty,
            !mimeType.isEmpty
        else {
            throw Self.operationFailure("invalidBulkTransfer")
        }
        guard await connection.isUsable else {
            throw Self.operationFailure(GuestProtocolFailure.disconnected.catalogName)
        }

        ensureAckRelay()
        receivedAck = nil
        var began = false
        var acknowledged = false
        do {
            var begin = GPBulkBegin()
            begin.kind = .file
            begin.name = name
            begin.mimeType = mimeType
            begin.size = size
            begin.sha256 = sha256
            var beginFrame = GPBulkFrame()
            beginFrame.transferID = transferID
            beginFrame.kind = .begin(begin)
            try await send(beginFrame)
            began = true

            guard !Task.isCancelled else {
                throw Self.operationFailure("cancelled")
            }
            var offset: UInt64 = 0
            while offset < size {
                if Task.isCancelled {
                    throw Self.operationFailure("cancelled")
                }
                let count = Int(min(UInt64(Self.maximumChunkSize), size - offset))
                let chunk = try Self.readChunk(fileDescriptor: fileHandle.fileDescriptor, offset: offset, count: count)
                var chunkFrame = GPBulkFrame()
                chunkFrame.transferID = transferID
                chunkFrame.kind = .chunk(chunk)
                try await send(chunkFrame)
                offset += UInt64(chunk.count)
            }

            // Register the expected transfer before writing End so a fast receiver cannot race past the waiter.
            expectedAckTransferID = transferID
            var end = GPBulkEnd()
            end.sha256 = sha256
            var endFrame = GPBulkFrame()
            endFrame.transferID = transferID
            endFrame.kind = .end(end)
            try await send(endFrame)

            let ack = try await waitForAck(transferID: transferID)
            try Self.requireSuccess(ack.status)
            acknowledged = true
            expectedAckTransferID = nil
            receivedAck = nil
        } catch let failure as GuestAgentFailure {
            expectedAckTransferID = nil
            receivedAck = nil
            ackTimeoutTask?.cancel()
            ackTimeoutTask = nil
            if began, !acknowledged {
                await sendAbortBestEffort(transferID: transferID)
            }
            throw failure
        } catch {
            expectedAckTransferID = nil
            receivedAck = nil
            ackTimeoutTask?.cancel()
            ackTimeoutTask = nil
            if began, !acknowledged {
                await sendAbortBestEffort(transferID: transferID)
            }
            throw Self.operationFailure("bulkTransferFailed")
        }
    }

    private func acquireTransfer() async {
        guard transferInFlight else {
            transferInFlight = true
            return
        }
        await withCheckedContinuation { transferWaiters.append($0) }
    }

    private func releaseTransfer() {
        if transferWaiters.isEmpty {
            transferInFlight = false
        } else {
            transferWaiters.removeFirst().resume()
        }
    }

    private func ensureAckRelay() {
        guard ackRelay == nil else {
            return
        }
        let frames = connection.bulkFrames
        ackRelay = Task { [weak self] in
            for await frame in frames {
                await self?.receiveAck(frame)
            }
            await self?.acknowledgementStreamEnded()
        }
    }

    private func receiveAck(_ frame: GPBulkFrame) {
        guard frame.transferID == expectedAckTransferID, case .ack(let ack)? = frame.kind else {
            return
        }
        if let continuation = ackContinuation {
            ackContinuation = nil
            ackTimeoutTask?.cancel()
            ackTimeoutTask = nil
            continuation.resume(returning: .success(ack))
        } else {
            receivedAck = ack
        }
    }

    private func acknowledgementStreamEnded() {
        ackStreamEnded = true
        guard let continuation = ackContinuation else {
            return
        }
        ackContinuation = nil
        ackTimeoutTask?.cancel()
        ackTimeoutTask = nil
        continuation.resume(returning: .failure(Self.operationFailure(GuestProtocolFailure.disconnected.catalogName)))
    }

    private func waitForAck(transferID: UInt64) async throws(GuestAgentFailure) -> GPBulkAck {
        if let receivedAck {
            return receivedAck
        }
        if ackStreamEnded {
            throw Self.operationFailure(GuestProtocolFailure.disconnected.catalogName)
        }
        let result: Result<GPBulkAck, GuestAgentFailure> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                ackContinuation = continuation
                ackTimeoutTask = Task {
                    do {
                        try await Task.sleep(for: acknowledgementTimeout)
                    } catch {
                        return
                    }
                    self.acknowledgementTimedOut(transferID: transferID)
                }
            }
        } onCancel: {
            Task { await self.cancelAckWait(transferID: transferID) }
        }
        switch result {
        case .success(let ack):
            return ack
        case .failure(let failure):
            throw failure
        }
    }

    private func acknowledgementTimedOut(transferID: UInt64) {
        guard expectedAckTransferID == transferID, let continuation = ackContinuation else {
            return
        }
        ackContinuation = nil
        ackTimeoutTask = nil
        continuation.resume(returning: .failure(Self.operationFailure("bulkAckTimedOut")))
    }

    private func cancelAckWait(transferID: UInt64) {
        guard expectedAckTransferID == transferID, let continuation = ackContinuation else {
            return
        }
        ackContinuation = nil
        ackTimeoutTask?.cancel()
        ackTimeoutTask = nil
        continuation.resume(returning: .failure(Self.operationFailure("cancelled")))
    }

    private func send(_ frame: GPBulkFrame) async throws(GuestAgentFailure) {
        do throws(GuestProtocolFailure) {
            try await connection.sendBulkFrame(frame)
        } catch {
            throw .operation(error)
        }
    }

    private func sendAbortBestEffort(transferID: UInt64) async {
        var abort = GPBulkAbort()
        abort.reason = "hostTransferFailed"
        var frame = GPBulkFrame()
        frame.transferID = transferID
        frame.kind = .abort(abort)
        try? await send(frame)
    }

    private static func readChunk(fileDescriptor: Int32, offset: UInt64, count: Int) throws(GuestAgentFailure) -> Data {
        var chunk = Data(count: count)
        let readCount = chunk.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else {
                return -1
            }
            var totalRead = 0
            while totalRead < count {
                let result = pread(
                    fileDescriptor,
                    baseAddress.advanced(by: totalRead),
                    count - totalRead,
                    off_t(offset + UInt64(totalRead))
                )
                if result < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return -1
                }
                if result == 0 {
                    return totalRead
                }
                totalRead += result
            }
            return totalRead
        }
        guard readCount == count else {
            throw operationFailure("bulkFileReadFailed")
        }
        return chunk
    }

    private static func requireSuccess(_ status: GPBulkAckStatus) throws(GuestAgentFailure) {
        switch status {
        case .ok:
            return
        case .hashMismatch:
            throw operationFailure("bulkAck.hashMismatch")
        case .tooLarge:
            throw operationFailure("bulkAck.tooLarge")
        case .rejected:
            throw operationFailure("bulkAck.rejected")
        case .unspecified:
            throw operationFailure("bulkAck.unspecified")
        case .UNRECOGNIZED(let rawValue):
            throw operationFailure("bulkAck.unknownStatus.\(rawValue)")
        }
    }

    private static func operationFailure(_ reason: String) -> GuestAgentFailure {
        .operationFailed(reason: reason)
    }
}
