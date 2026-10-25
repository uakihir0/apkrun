import CryptoKit
import Foundation
import GuestProtocol
import Testing

@testable import RuntimeCore

private func helloOnBulkEndpoint(_ endpoint: GuestEndpoint, _ agent: InMemoryAgent, _ number: Int) {
    agent.sendHello(capabilities: ["core.v1", "bulk.v1"])
}

private func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition())
}

private func temporaryFile(containing data: Data) throws -> (URL, FileHandle) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-bulk-\(UUID().uuidString)")
    try data.write(to: url, options: .atomic)
    return (url, try FileHandle(forReadingFrom: url))
}

@Test(.timeLimit(.minutes(1)))
func bulkTransferStreamsBoundedChunksAndPreservesTheSharedFileOffset() async throws {
    let data = Data((0..<(GuestBulkChannel.maximumChunkSize * 2 + 31)).map { UInt8($0 % 251) })
    let (url, file) = try temporaryFile(containing: data)
    defer {
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }
    try file.seek(toOffset: 17)

    let transport = InMemoryTransport(configure: helloOnBulkEndpoint)
    let connection = GuestConnection(
        endpoint: .guestBulk,
        transport: transport,
        presentedToken: Data(repeating: 9, count: 16)
    )
    _ = try await connection.open()
    let channel = GuestBulkChannel(connection: connection)
    let transferID: UInt64 = 42
    let digest = Data(SHA256.hash(data: data))

    let transfer = Task {
        try await channel.transferFile(
            file,
            transferID: transferID,
            name: "sample.dat",
            mimeType: "application/octet-stream",
            size: UInt64(data.count),
            sha256: digest
        )
    }

    let agent = transport.agents[0]
    try await eventually {
        agent.envelopes.contains { envelope in
            guard case .bulk(let frame)? = envelope.body else { return false }
            if case .end? = frame.kind { return frame.transferID == transferID }
            return false
        }
    }
    // Acknowledgements for other IDs must not complete this transfer.
    agent.sendBulkAck(transferID: transferID + 2)
    agent.sendBulkAck(transferID: transferID)
    try await transfer.value

    let frames = agent.envelopes.compactMap { envelope -> GPBulkFrame? in
        guard case .bulk(let frame)? = envelope.body else { return nil }
        return frame
    }.filter { $0.transferID == transferID }
    guard case .begin(let begin)? = frames.first?.kind else {
        Issue.record("the transfer did not start with BulkBegin")
        return
    }
    guard case .end(let end)? = frames.last?.kind else {
        Issue.record("the transfer did not end with BulkEnd")
        return
    }
    let chunks = frames.compactMap { frame -> Data? in
        if case .chunk(let chunk)? = frame.kind { return chunk }
        return nil
    }
    #expect(begin.kind == .file)
    #expect(begin.name == "sample.dat")
    #expect(begin.mimeType == "application/octet-stream")
    #expect(begin.size == UInt64(data.count))
    #expect(begin.sha256 == digest)
    #expect(end.sha256 == digest)
    #expect(chunks.count == 3)
    #expect(chunks.allSatisfy { $0.count <= GuestBulkChannel.maximumChunkSize })
    #expect(chunks.reduce(into: Data()) { $0.append($1) } == data)
    let finalOffset = file.offsetInFile
    #expect(finalOffset == 17)
}

@Test(.timeLimit(.minutes(1)))
func bulkTransferReportsReceiverHashRejectionAndAbortsTheTransfer() async throws {
    let data = Data("file bytes".utf8)
    let (url, file) = try temporaryFile(containing: data)
    defer {
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }
    let transport = InMemoryTransport(configure: helloOnBulkEndpoint)
    let connection = GuestConnection(
        endpoint: .guestBulk,
        transport: transport,
        presentedToken: Data(repeating: 5, count: 16)
    )
    _ = try await connection.open()
    let channel = GuestBulkChannel(connection: connection)
    let transferID: UInt64 = 8
    let transfer = Task {
        try await channel.transferFile(
            file,
            transferID: transferID,
            name: "sample.txt",
            mimeType: "text/plain",
            size: UInt64(data.count),
            sha256: Data(repeating: 0, count: 32)
        )
    }
    let agent = transport.agents[0]
    try await eventually {
        agent.envelopes.contains { envelope in
            guard case .bulk(let frame)? = envelope.body else { return false }
            if case .end? = frame.kind { return frame.transferID == transferID }
            return false
        }
    }
    agent.sendBulkAck(transferID: transferID, status: .hashMismatch)

    do {
        try await transfer.value
        Issue.record("a hash mismatch acknowledgement was accepted")
    } catch let failure as GuestAgentFailure {
        #expect(failure == .operationFailed(reason: "bulkAck.hashMismatch"))
    }
    try await eventually {
        agent.envelopes.contains { envelope in
            guard case .bulk(let frame)? = envelope.body else { return false }
            if case .abort? = frame.kind { return frame.transferID == transferID }
            return false
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func bulkTransferRejectsOddIDsInvalidDigestsAndOversizedFilesBeforeSending() async throws {
    let data = Data()
    let (url, file) = try temporaryFile(containing: data)
    defer {
        try? file.close()
        try? FileManager.default.removeItem(at: url)
    }
    let transport = InMemoryTransport(configure: helloOnBulkEndpoint)
    let connection = GuestConnection(
        endpoint: .guestBulk,
        transport: transport,
        presentedToken: Data(repeating: 3, count: 16)
    )
    _ = try await connection.open()
    let channel = GuestBulkChannel(connection: connection)
    for (transferID, size, digest) in [
        (UInt64(3), UInt64(0), Data(repeating: 1, count: 32)),
        (UInt64(4), UInt64(0), Data(repeating: 1, count: 31)),
        (UInt64(6), GuestBulkChannel.maximumTransferSize + 1, Data(repeating: 1, count: 32)),
    ] {
        do {
            try await channel.transferFile(
                file,
                transferID: transferID,
                name: "sample",
                mimeType: "application/octet-stream",
                size: size,
                sha256: digest
            )
            Issue.record("invalid transfer metadata was accepted")
        } catch let failure {
            #expect(failure == .operationFailed(reason: "invalidBulkTransfer"))
        }
    }
    let transferFrames = transport.agents[0].envelopes.filter { envelope in
        if case .bulk? = envelope.body { return true }
        return false
    }
    #expect(transferFrames.isEmpty)
}
