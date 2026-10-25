import CryptoKit
import Foundation
import GuestProtocol
import Testing

@testable import RuntimeCore

private func bulkFileReceiverConnection() async throws -> (GuestConnection, InMemoryAgent) {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello(capabilities: ["core.v1", "bulk.v1"])
    }
    let connection = GuestConnection(
        endpoint: .guestBulk,
        transport: transport,
        presentedToken: Data(repeating: 11, count: 16)
    )
    _ = try await connection.open()
    return (connection, transport.agents[0])
}

private func bulkTemporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-export-\(UUID().uuidString)")
}

private func exportBegin(transferID: UInt64, size: UInt64, kind: GPBulkKind = .file) -> GPBulkFrame {
    var begin = GPBulkBegin()
    begin.kind = kind
    begin.name = "report.txt"
    begin.mimeType = "text/plain"
    begin.size = size
    var frame = GPBulkFrame()
    frame.transferID = transferID
    frame.kind = .begin(begin)
    return frame
}

private func exportChunk(transferID: UInt64, bytes: Data) -> GPBulkFrame {
    var frame = GPBulkFrame()
    frame.transferID = transferID
    frame.kind = .chunk(bytes)
    return frame
}

private func exportEnd(transferID: UInt64, digest: Data) -> GPBulkFrame {
    var end = GPBulkEnd()
    end.sha256 = digest
    var frame = GPBulkFrame()
    frame.transferID = transferID
    frame.kind = .end(end)
    return frame
}

private func exportAbort(transferID: UInt64) -> GPBulkFrame {
    var abort = GPBulkAbort()
    abort.reason = "cancelled"
    var frame = GPBulkFrame()
    frame.transferID = transferID
    frame.kind = .abort(abort)
    return frame
}

private func ackStatus(_ agent: InMemoryAgent, transferID: UInt64) -> GPBulkAckStatus? {
    agent.envelopes.compactMap { envelope -> GPBulkFrame? in
        guard case .bulk(let frame)? = envelope.body else { return nil }
        return frame
    }.first { frame in
        guard frame.transferID == transferID, case .ack? = frame.kind else { return false }
        return true
    }?.ack.status
}

private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverPreservesAFrameThatArrivesImmediatelyAfterAccept() async throws {
    let (connection, agent) = try await bulkFileReceiverConnection()
    let payload = Data("offered file".utf8)
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(
        expectedSize: UInt64(payload.count),
        temporaryFileURL: temporaryURL
    )
    try await receiver.bind(transferID: 19)

    // This is the earliest valid post-accept ordering: the guest begins sending before receive() starts.
    agent.sendBulkFrame(exportBegin(transferID: 19, size: UInt64(payload.count)))
    agent.sendBulkFrame(exportChunk(transferID: 19, bytes: payload))
    agent.sendBulkFrame(exportEnd(transferID: 19, digest: Data(SHA256.hash(data: payload))))

    let task = Task { try await receiver.receive() }
    let result = try await task.value
    #expect(result == temporaryURL)
    #expect(try Data(contentsOf: result) == payload)
    #expect(ackStatus(agent, transferID: 19) == .ok)
    task.cancel()
    await receiver.cancel()
    #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
    await connection.close()
    try? FileManager.default.removeItem(at: temporaryURL)
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverCancellationAfterEndDoesNotUndoAnAcknowledgedTransfer() async throws {
    let (connection, agent) = try await bulkFileReceiverConnection()
    try await eventually {
        agent.envelopes.contains {
            if case .helloAck? = $0.body { return true }
            return false
        }
    }
    let gate = agent.blockNextHostWrite()
    let payload = Data("commit before acknowledgement".utf8)
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(
        expectedSize: UInt64(payload.count),
        temporaryFileURL: temporaryURL
    )
    try await receiver.bind(transferID: 39)
    agent.sendBulkFrame(exportBegin(transferID: 39, size: UInt64(payload.count)))
    agent.sendBulkFrame(exportChunk(transferID: 39, bytes: payload))
    agent.sendBulkFrame(exportEnd(transferID: 39, digest: Data(SHA256.hash(data: payload))))

    let task = Task { try await receiver.receive() }
    await gate.waitUntilBlocked()
    task.cancel()
    gate.release()

    let result = try await task.value
    #expect(result == temporaryURL)
    #expect(try Data(contentsOf: result) == payload)
    #expect(ackStatus(agent, transferID: 39) == .ok)
    await connection.close()
    try? FileManager.default.removeItem(at: temporaryURL)
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverUsesArrivalOrderAndRejectsChecksumMismatch() async throws {
    let (connection, agent) = try await bulkFileReceiverConnection()
    let expected = Data("first-second".utf8)
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(
        expectedSize: UInt64(expected.count),
        temporaryFileURL: temporaryURL
    )
    try await receiver.bind(transferID: 21)
    agent.sendBulkFrame(exportBegin(transferID: 21, size: UInt64(expected.count)))
    agent.sendBulkFrame(exportChunk(transferID: 21, bytes: Data("second".utf8)))
    agent.sendBulkFrame(exportChunk(transferID: 21, bytes: Data("first-".utf8)))
    agent.sendBulkFrame(exportEnd(transferID: 21, digest: Data(SHA256.hash(data: expected))))

    do {
        _ = try await receiver.receive()
        Issue.record("chunks received in the wrong order passed verification")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .checksumMismatch)
    }
    #expect(ackStatus(agent, transferID: 21) == .hashMismatch)
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverRejectsWrongTransferIDAndRemovesTheTemporaryFile() async throws {
    let (connection, agent) = try await bulkFileReceiverConnection()
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(expectedSize: 0, temporaryFileURL: temporaryURL)
    try await receiver.bind(transferID: 23)
    agent.sendBulkFrame(exportBegin(transferID: 25, size: 0))

    do {
        _ = try await receiver.receive()
        Issue.record("a frame for another transfer ID was accepted")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .malformedFrame)
    }
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(await connection.closeReason == .malformedFrame)
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverRejectsOfferSizeMismatchBeforeWriting() async throws {
    let (connection, agent) = try await bulkFileReceiverConnection()
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(expectedSize: 4, temporaryFileURL: temporaryURL)
    try await receiver.bind(transferID: 27)
    agent.sendBulkFrame(exportBegin(transferID: 27, size: 3))

    do {
        _ = try await receiver.receive()
        Issue.record("a begin frame with a different offered size was accepted")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .malformedFrame)
    }
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(await connection.closeReason == .malformedFrame)
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverRejectsPrematureEndWithARejectedAck() async throws {
    let (connection, agent) = try await bulkFileReceiverConnection()
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(expectedSize: 4, temporaryFileURL: temporaryURL)
    try await receiver.bind(transferID: 29)
    agent.sendBulkFrame(exportBegin(transferID: 29, size: 4))
    agent.sendBulkFrame(exportChunk(transferID: 29, bytes: Data([1, 2, 3])))
    agent.sendBulkFrame(exportEnd(transferID: 29, digest: Data(SHA256.hash(data: Data([1, 2, 3])))))

    do {
        _ = try await receiver.receive()
        Issue.record("a transfer with a short byte count was accepted")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .sizeMismatch)
    }
    #expect(ackStatus(agent, transferID: 29) == .rejected)
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(await connection.closeReason == .malformedFrame)
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverCleansTemporaryFileOnGuestAbortAndCancellation() async throws {
    let (connection, agent) = try await bulkFileReceiverConnection()
    let abortedURL = bulkTemporaryURL()
    let aborted = try await connection.prepareBulkFileReceive(expectedSize: 10, temporaryFileURL: abortedURL)
    try await aborted.bind(transferID: 31)
    agent.sendBulkFrame(exportBegin(transferID: 31, size: 10))
    agent.sendBulkFrame(exportAbort(transferID: 31))
    do {
        _ = try await aborted.receive()
        Issue.record("an aborted transfer succeeded")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .aborted)
    }
    #expect(!FileManager.default.fileExists(atPath: abortedURL.path))

    let cancelledURL = bulkTemporaryURL()
    let cancelled = try await connection.prepareBulkFileReceive(expectedSize: 10, temporaryFileURL: cancelledURL)
    try await cancelled.bind(transferID: 33)
    let task = Task { try await cancelled.receive() }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("a cancelled transfer succeeded")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .cancelled)
    }
    #expect(!FileManager.default.fileExists(atPath: cancelledURL.path))
    #expect(await connection.closeReason == .disconnected)
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverCleansTemporaryFileOnDisconnect() async throws {
    let (connection, _) = try await bulkFileReceiverConnection()
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(expectedSize: 10, temporaryFileURL: temporaryURL)
    try await receiver.bind(transferID: 35)
    let task = Task { try await receiver.receive() }
    await connection.close()
    do {
        _ = try await task.value
        Issue.record("a transfer that disconnected succeeded")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .disconnected)
    }
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverCanBeDiscardedBeforeAcceptanceAndCleansOnConnectionClose() async throws {
    let (connection, _) = try await bulkFileReceiverConnection()
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(expectedSize: 10, temporaryFileURL: temporaryURL)
    #expect(FileManager.default.fileExists(atPath: temporaryURL.path))
    await receiver.cancel()
    await receiver.cancel()
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(await connection.isUsable)

    let closeURL = bulkTemporaryURL()
    _ = try await connection.prepareBulkFileReceive(expectedSize: 5, temporaryFileURL: closeURL)
    #expect(FileManager.default.fileExists(atPath: closeURL.path))
    await connection.close()
    #expect(!FileManager.default.fileExists(atPath: closeURL.path))
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverRejectsChunksOverOneMiB() async throws {
    let (connection, agent) = try await bulkFileReceiverConnection()
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(
        expectedSize: UInt64(GuestBulkFileReceiver.maximumChunkSize + 1),
        temporaryFileURL: temporaryURL
    )
    try await receiver.bind(transferID: 37)
    agent.sendBulkFrame(
        exportBegin(
            transferID: 37,
            size: UInt64(GuestBulkFileReceiver.maximumChunkSize + 1)
        ))
    agent.sendBulkFrame(
        exportChunk(
            transferID: 37,
            bytes: Data(repeating: 1, count: GuestBulkFileReceiver.maximumChunkSize + 1)
        ))
    do {
        _ = try await receiver.receive()
        Issue.record("an oversized bulk chunk was accepted")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .malformedFrame)
    }
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(await connection.closeReason == .malformedFrame)
}

@Test(.timeLimit(.minutes(1)))
func bulkFileReceiverRejectsEvenAndOversizedTransferBinding() async throws {
    let (connection, _) = try await bulkFileReceiverConnection()
    let temporaryURL = bulkTemporaryURL()
    let receiver = try await connection.prepareBulkFileReceive(expectedSize: 0, temporaryFileURL: temporaryURL)
    do {
        try await receiver.bind(transferID: 34)
        Issue.record("an even transfer ID was bound")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .invalidOffer)
    }
    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(await connection.closeReason == .malformedFrame)

    let (openConnection, _) = try await bulkFileReceiverConnection()
    let tooLargeURL = bulkTemporaryURL()
    do {
        _ = try await openConnection.prepareBulkFileReceive(
            expectedSize: GuestBulkFileReceiver.maximumTransferSize + 1,
            temporaryFileURL: tooLargeURL
        )
        Issue.record("an over-limit file offer was prepared")
    } catch let failure as GuestBulkFileReceiveFailure {
        #expect(failure == .invalidOffer)
    }
    #expect(!FileManager.default.fileExists(atPath: tooLargeURL.path))
}
