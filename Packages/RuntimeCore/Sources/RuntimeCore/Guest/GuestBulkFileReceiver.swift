import CryptoKit
import Foundation
import GuestProtocol

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// A failure while receiving an offered file from the Guest Agent.
public enum GuestBulkFileReceiveFailure: Error, Equatable, Sendable {
    /// The transfer ID, size, endpoint, or receive state was not valid.
    case invalidOffer
    /// The guest sent a frame that did not match the active transfer protocol.
    case malformedFrame
    /// The guest cancelled the offered transfer.
    case aborted
    /// The received bytes did not match the size announced by the offer.
    case sizeMismatch
    /// The received bytes did not match the SHA-256 digest.
    case checksumMismatch
    /// The bulk connection ended before the transfer completed.
    case disconnected
    /// The caller cancelled the receive operation.
    case cancelled
    /// The temporary destination could not be created, written, synchronized, or removed.
    case destinationFailure
    /// The prepared receiver has already been used.
    case alreadyConsumed
}

/// Receives one offer-bound guest file into a new temporary file.
///
/// The caller prepares this receiver before accepting the export, binds the returned transfer ID, and then calls
/// ``receive()``. Inbound frames are buffered with backpressure while the accept response is in flight. The file is
/// retained at `temporaryFileURL` only after the full byte count and SHA-256 have been verified.
public actor GuestBulkFileReceiver {
    /// The protocol's maximum file size.
    public static let maximumTransferSize: UInt64 = 2_147_483_648
    /// The protocol's maximum chunk size.
    public static let maximumChunkSize = 1_048_576

    private weak var connection: GuestConnection?
    private let receiveID: UUID
    private let expectedSize: UInt64
    private let temporaryFileURL: URL
    private let inbox: GuestBulkFrameInbox
    private var fileHandle: FileHandle?
    private var transferID: UInt64?
    private var isConsumed = false
    private var isFinished = false

    init(
        connection: GuestConnection,
        inbox: GuestBulkFrameInbox,
        receiveID: UUID,
        expectedSize: UInt64,
        temporaryFileURL: URL
    ) throws(GuestBulkFileReceiveFailure) {
        guard expectedSize <= Self.maximumTransferSize else {
            throw .invalidOffer
        }
        let descriptor = temporaryFileURL.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw .destinationFailure
        }
        self.connection = connection
        self.inbox = inbox
        self.receiveID = receiveID
        self.expectedSize = expectedSize
        self.temporaryFileURL = temporaryFileURL
        fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Binds the ID returned by the accepted export. The receive queue is already armed, so the guest may start
    /// sending before the control response reaches the caller.
    public func bind(transferID: UInt64) async throws(GuestBulkFileReceiveFailure) {
        guard !isConsumed, !isFinished, self.transferID == nil else {
            throw .alreadyConsumed
        }
        guard transferID > 0, !transferID.isMultiple(of: 2) else {
            cleanupDestination()
            isFinished = true
            await connection?.failBulkFileReceive(receiveID: receiveID, reason: .malformedFrame)
            throw .invalidOffer
        }
        self.transferID = transferID
    }

    /// Cancels this prepared or active receive and removes its temporary file.
    ///
    /// Cancelling before binding simply disarms the pending receiver. Cancelling an accepted transfer closes the
    /// bulk connection so the guest stops sending the already accepted export.
    public func cancel() async {
        guard !isFinished else {
            return
        }
        cleanupDestination()
        isFinished = true
        guard let connection else {
            return
        }
        if transferID == nil {
            await connection.finishBulkFileReceive(receiveID: receiveID)
        } else {
            await connection.failBulkFileReceive(receiveID: receiveID, reason: .disconnected)
        }
    }

    func connectionDidClose() {
        guard !isFinished else {
            return
        }
        cleanupDestination()
        isFinished = true
    }

    /// Consumes the transfer and returns its verified temporary file URL.
    ///
    /// Every failure truncates and removes the temporary file. The receiver sends a `BulkAck` only after it has
    /// validated the terminal size and digest.
    public func receive() async throws(GuestBulkFileReceiveFailure) -> URL {
        guard transferID != nil else {
            cleanupDestination()
            isFinished = true
            await connection?.failBulkFileReceive(receiveID: receiveID, reason: .malformedFrame)
            throw .invalidOffer
        }
        guard !isConsumed else {
            throw .alreadyConsumed
        }
        isConsumed = true

        do {
            let result = try await withTaskCancellationHandler {
                try await receiveFrames()
            } onCancel: {
                Task { await self.cancelReceive() }
            }
            isFinished = true
            await connection?.finishBulkFileReceive(receiveID: receiveID)
            return result
        } catch let failure as GuestBulkFileReceiveFailure {
            cleanupDestination()
            isFinished = true
            if failure == .malformedFrame || failure == .sizeMismatch {
                await connection?.failBulkFileReceive(receiveID: receiveID, reason: .malformedFrame)
            } else if failure == .destinationFailure {
                await connection?.failBulkFileReceive(receiveID: receiveID, reason: .disconnected)
            } else {
                await connection?.finishBulkFileReceive(receiveID: receiveID)
            }
            throw failure
        } catch {
            cleanupDestination()
            isFinished = true
            await connection?.failBulkFileReceive(receiveID: receiveID, reason: .disconnected)
            throw .destinationFailure
        }
    }

    private func receiveFrames() async throws(GuestBulkFileReceiveFailure) -> URL {
        guard let transferID else {
            throw .invalidOffer
        }
        var began = false
        var bytesReceived: UInt64 = 0
        var hasher = SHA256()
        var beginDigest: Data?

        while let frame = await inbox.next(receiveID: receiveID) {
            guard !Task.isCancelled else {
                throw .cancelled
            }
            guard frame.transferID == transferID, let kind = frame.kind else {
                throw .malformedFrame
            }

            switch kind {
            case .begin(let begin):
                guard !began, begin.kind == .file, begin.size == expectedSize,
                    begin.size <= Self.maximumTransferSize,
                    !begin.hasSha256 || begin.sha256.count == 32
                else {
                    throw .malformedFrame
                }
                began = true
                if begin.hasSha256 {
                    beginDigest = begin.sha256
                }
            case .chunk(let chunk):
                guard began, !chunk.isEmpty, chunk.count <= Self.maximumChunkSize,
                    UInt64(chunk.count) <= expectedSize - bytesReceived
                else {
                    throw .malformedFrame
                }
                do {
                    try fileHandle?.write(contentsOf: chunk)
                } catch {
                    throw .destinationFailure
                }
                hasher.update(data: chunk)
                bytesReceived += UInt64(chunk.count)
            case .end(let end):
                guard began else {
                    throw .malformedFrame
                }
                guard bytesReceived == expectedSize else {
                    cleanupDestination()
                    isFinished = true
                    try await sendAcknowledgement(.rejected)
                    throw .sizeMismatch
                }
                let digest = Data(hasher.finalize())
                let expectedDigest: Data
                if let beginDigest {
                    guard end.sha256.isEmpty else {
                        throw .malformedFrame
                    }
                    expectedDigest = beginDigest
                } else {
                    guard end.sha256.count == 32 else {
                        throw .malformedFrame
                    }
                    expectedDigest = end.sha256
                }
                guard digest == expectedDigest else {
                    cleanupDestination()
                    isFinished = true
                    try await sendAcknowledgement(.hashMismatch)
                    throw .checksumMismatch
                }
                guard !Task.isCancelled else {
                    throw .cancelled
                }
                do {
                    try fileHandle?.synchronize()
                    try fileHandle?.close()
                    fileHandle = nil
                } catch {
                    throw .destinationFailure
                }
                isFinished = true
                try await sendAcknowledgement(.ok)
                return temporaryFileURL
            case .abort:
                throw .aborted
            case .ack:
                throw .malformedFrame
            }
        }

        if Task.isCancelled {
            throw .cancelled
        }
        let reason = await connection?.closeReason
        guard reason == nil else {
            throw .disconnected
        }
        throw .disconnected
    }

    private func sendAcknowledgement(_ status: GPBulkAckStatus) async throws(GuestBulkFileReceiveFailure) {
        guard let transferID, let connection else {
            throw .disconnected
        }
        var acknowledgement = GPBulkAck()
        acknowledgement.status = status
        var frame = GPBulkFrame()
        frame.transferID = transferID
        frame.kind = .ack(acknowledgement)
        do throws(GuestProtocolFailure) {
            try await connection.sendBulkFrame(frame)
        } catch {
            throw .disconnected
        }
    }

    private func cancelReceive() async {
        await cancel()
    }

    private func cleanupDestination() {
        if let fileHandle {
            try? fileHandle.truncate(atOffset: 0)
            try? fileHandle.close()
            self.fileHandle = nil
        }
        try? FileManager.default.removeItem(at: temporaryFileURL)
    }
}

/// A single-consumer mailbox with at most one queued frame. The connection's reader waits until the next frame is
/// consumed, so a large transfer applies backpressure instead of entering an unbounded or lossy stream.
actor GuestBulkFrameInbox {
    private var queuedFrame: GPBulkFrame?
    private var nextWaiter: CheckedContinuation<GPBulkFrame?, Never>?
    private var producerWaiter: CheckedContinuation<Bool, Never>?
    private var isClosed = false

    private var activeReceiveID: UUID?

    func activate(receiveID: UUID) {
        activeReceiveID = receiveID
        isClosed = false
        queuedFrame = nil
    }

    func enqueue(_ frame: GPBulkFrame, receiveID: UUID) async -> Bool {
        guard activeReceiveID == receiveID, !isClosed else {
            return false
        }
        if let nextWaiter {
            self.nextWaiter = nil
            nextWaiter.resume(returning: frame)
            return true
        }
        guard queuedFrame == nil else {
            return false
        }
        queuedFrame = frame
        return await withCheckedContinuation { producerWaiter = $0 }
    }

    func next(receiveID: UUID) async -> GPBulkFrame? {
        guard activeReceiveID == receiveID else {
            return nil
        }
        if let queuedFrame {
            self.queuedFrame = nil
            let producerWaiter = self.producerWaiter
            self.producerWaiter = nil
            producerWaiter?.resume(returning: true)
            return queuedFrame
        }
        guard activeReceiveID == receiveID, !isClosed else {
            return nil
        }
        return await withCheckedContinuation { nextWaiter = $0 }
    }

    func deactivate(receiveID: UUID) {
        guard activeReceiveID == receiveID else {
            return
        }
        activeReceiveID = nil
        queuedFrame = nil
        let producerWaiter = self.producerWaiter
        self.producerWaiter = nil
        producerWaiter?.resume(returning: false)
        let nextWaiter = self.nextWaiter
        self.nextWaiter = nil
        nextWaiter?.resume(returning: nil)
    }

    func close() {
        isClosed = true
        activeReceiveID = nil
        queuedFrame = nil
        let producerWaiter = self.producerWaiter
        self.producerWaiter = nil
        producerWaiter?.resume(returning: false)
        let nextWaiter = self.nextWaiter
        self.nextWaiter = nil
        nextWaiter?.resume(returning: nil)
    }
}
