import Foundation
import GuestProtocol
import Testing

@testable import RuntimeCore

/// The input endpoint of `GuestConnection`: the batches it writes, and the acks it delivers (guest-protocol.md §3,
/// §9; input.md §8), run against an in-memory agent.

/// An agent that says hello on the channel of its endpoint.
private func helloOnly(_ endpoint: GuestEndpoint, _ agent: InMemoryAgent, _ number: Int) {
    agent.sendHello()
}

private func eventually(within seconds: Double = 5, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func batch(seq: UInt64) -> GPInputBatch {
    var batch = GPInputBatch()
    batch.batchSeq = seq
    batch.displayID = 0
    batch.hostSendNanos = 1
    var event = GPInputEvent()
    event.hostTimeNanos = 2
    event.kind = .cancelAll(GPCancelAll())
    batch.events = [event]
    return batch
}

@Test(.timeLimit(.minutes(1)))
func sendInputBatchWritesAnInputBatchEnvelope() async throws {
    let transport = InMemoryTransport(configure: helloOnly)
    let connection = GuestConnection(
        endpoint: .guestInput,
        transport: transport,
        presentedToken: Data(repeating: 7, count: 16)
    )
    _ = try await connection.open()
    try await connection.sendInputBatch(batch(seq: 1))
    try await connection.sendInputBatch(batch(seq: 2))
    let agent = transport.agents[0]
    try await eventually {
        agent.envelopes.filter { envelope in
            if case .inputBatch? = envelope.body { return true }
            return false
        }.count == 2
    }
    let batches: [GPInputBatch] = agent.envelopes.compactMap { envelope in
        if case .inputBatch(let batch)? = envelope.body { return batch }
        return nil
    }
    #expect(batches.map(\.batchSeq) == [1, 2])
    #expect(batches.allSatisfy { $0.events.count == 1 && $0.displayID == 0 })
    // Every envelope has its own id, and the batches keep their order on the stream.
    let ids = agent.envelopes.map(\.id)
    #expect(Set(ids).count == ids.count)
}

@Test(.timeLimit(.minutes(1)))
func anInputAckReachesTheInputAckStream() async throws {
    let transport = InMemoryTransport(configure: helloOnly)
    let connection = GuestConnection(
        endpoint: .guestInput,
        transport: transport,
        presentedToken: Data(repeating: 7, count: 16)
    )
    _ = try await connection.open()
    let reader = Task { () -> GPInputAck? in
        for await ack in connection.inputAcks {
            return ack
        }
        return nil
    }
    transport.agents[0].sendInputAck(batchSeq: 32, rejected: 2)
    let ack = await reader.value
    #expect(ack?.batchSeq == 32)
    #expect(ack?.rejectedEvents == 2)
    #expect(await connection.isUsable)
}

@Test(.timeLimit(.minutes(1)))
func sendInputBatchFailsWithTheConnectionFailureWhenItIsNotUsable() async throws {
    let transport = InMemoryTransport(configure: helloOnly)
    let connection = GuestConnection(
        endpoint: .guestInput,
        transport: transport,
        presentedToken: Data(repeating: 7, count: 16)
    )
    do {
        try await connection.sendInputBatch(batch(seq: 1))
        Issue.record("a batch was accepted on a connection that is not open")
    } catch {
        #expect(error == .disconnected)
    }
    #expect(transport.agents.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func theBacklogOfTheInputStreamDrainsOnceTheBatchesAreWritten() async throws {
    let transport = InMemoryTransport(configure: helloOnly)
    let connection = GuestConnection(
        endpoint: .guestInput,
        transport: transport,
        presentedToken: Data(repeating: 7, count: 16)
    )
    _ = try await connection.open()
    for seq in 1...8 {
        try await connection.sendInputBatch(batch(seq: UInt64(seq)))
    }
    try await eventually { await connection.pendingOutboundBytes == 0 }
    #expect(await connection.pendingOutboundBytes == 0)
}
