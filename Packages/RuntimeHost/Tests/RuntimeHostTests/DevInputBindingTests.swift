import Foundation
import GuestProtocol
import RuntimeAPI
import RuntimeCore
import Testing

@testable import RuntimeHost

private actor BindingInputChannel: InputChannel {
    nonisolated let acks: AsyncStream<GPInputAck>
    private(set) var batches: [GPInputBatch] = []
    private(set) var sendAttempts = 0
    private(set) var attemptedBatches: [GPInputBatch] = []
    private var isAlive = true
    private var shouldFailNextSend = false

    init() {
        let stream = AsyncStream.makeStream(of: GPInputAck.self)
        stream.continuation.finish()
        acks = stream.stream
    }

    func send(_ batch: GPInputBatch) async throws {
        sendAttempts += 1
        attemptedBatches.append(batch)
        if shouldFailNextSend {
            shouldFailNextSend = false
            isAlive = false
            throw GuestProtocolFailure.disconnected
        }
        guard isAlive else {
            throw GuestProtocolFailure.disconnected
        }
        batches.append(batch)
    }

    var pendingBytes: Int {
        0
    }

    func failNextSend() {
        shouldFailNextSend = true
    }

    func usable() -> Bool {
        isAlive
    }

    func cancelAllAttempts() -> Int {
        attemptedBatches.filter { batch in
            batch.events.contains { event in
                if case .cancelAll? = event.kind {
                    return true
                }
                return false
            }
        }.count
    }
}

private actor BindingAgentState {
    private let updates: AsyncStream<GuestAgentSupervisor.State>
    private let continuation: AsyncStream<GuestAgentSupervisor.State>.Continuation
    private var token: Data?
    private var channels: [DevInputBindingChannel]
    private var nextChannel = 0

    init(token: Data, channels: [DevInputBindingChannel]) {
        let stream = AsyncStream.makeStream(
            of: GuestAgentSupervisor.State.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        updates = stream.stream
        continuation = stream.continuation
        self.token = token
        self.channels = channels
        continuation.yield(.ready)
    }

    func stateUpdates() -> AsyncStream<GuestAgentSupervisor.State> {
        updates
    }

    func sessionToken() -> Data? {
        token
    }

    func openInputChannel() throws(GuestAgentFailure) -> DevInputBindingChannel {
        guard nextChannel < channels.count else {
            throw .operationFailed(reason: "disconnected")
        }
        defer { nextChannel += 1 }
        return channels[nextChannel]
    }

    func loseSession() {
        token = nil
        continuation.yield(.reconnecting)
    }

    func restoreSession(token: Data, channel: DevInputBindingChannel) {
        self.token = token
        channels.append(channel)
        continuation.yield(.ready)
    }
}

private func waitForBindingCondition(
    within duration: Duration = .seconds(2),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await condition())
}

private func bindingTouchBatch(at hostNanos: UInt64) -> RuntimeAPI.InputBatch {
    RuntimeAPI.InputBatch(events: [
        .touch(
            RuntimeAPI.WireTouchEvent(
                phase: .down,
                pointerID: 0,
                position: .init(x: 1, y: 1),
                time: .init(hostNanos: hostNanos)
            ))
    ])
}

@Test(.timeLimit(.minutes(1)))
func releasesTheDeadInputRouteAndRebindsWhenTheGuestSessionReturns() async throws {
    let oldInput = BindingInputChannel()
    let middleInput = BindingInputChannel()
    let newInput = BindingInputChannel()
    let oldChannel = DevInputBindingChannel(
        input: oldInput,
        isUsable: { await oldInput.usable() }
    )
    let middleChannel = DevInputBindingChannel(
        input: middleInput,
        isUsable: { await middleInput.usable() }
    )
    let newChannel = DevInputBindingChannel(
        input: newInput,
        isUsable: { await newInput.usable() }
    )
    let agent = BindingAgentState(token: Data([1]), channels: [oldChannel])
    let route = DevInputRoute()
    await route.focusChanged(true, generation: 1)
    let binding = DevInputBinding(
        routes: [route],
        stateUpdates: { await agent.stateUpdates() },
        sessionToken: { await agent.sessionToken() },
        openInputChannel: { () async throws(GuestAgentFailure) -> DevInputBindingChannel in
            try await agent.openInputChannel()
        },
        focusDisplay: { _ in },
        adbShellInvocationCount: { 0 },
        logSink: nil
    )
    let task = Task { await binding.run { _ in } }
    defer { task.cancel() }

    try await waitForBindingCondition {
        await oldInput.batches.count == 1
    }
    await route.send(bindingTouchBatch(at: 1))
    try await waitForBindingCondition {
        await oldInput.batches.count == 2
    }

    await agent.loseSession()
    let lossDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < lossDeadline {
        await route.send(bindingTouchBatch(at: 2))
        if await route.counters().droppedNotRunning > 0 {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await route.counters().droppedNotRunning > 0)
    try await waitForBindingCondition {
        await oldInput.cancelAllAttempts() >= 2
    }
    let attemptsAfterLoss = await oldInput.sendAttempts
    await route.send(bindingTouchBatch(at: 3))
    #expect(await oldInput.sendAttempts == attemptsAfterLoss)

    await agent.restoreSession(token: Data([2]), channel: middleChannel)
    try await waitForBindingCondition {
        await middleInput.batches.count == 1
    }
    await route.send(bindingTouchBatch(at: 4))
    try await waitForBindingCondition {
        await middleInput.batches.count == 2
    }

    // An event already in flight when the input stream dies is recorded as a channel drop.
    await middleInput.failNextSend()
    await route.send(bindingTouchBatch(at: 5))
    try await waitForBindingCondition {
        await route.counters().droppedChannel > 0
    }

    // If reopening the input-only channel fails, later input must still see an unbound route rather than touching the
    // dead channel again.
    let droppedWhileUnbound = await route.counters().droppedNotRunning
    let failureDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < failureDeadline {
        await route.send(bindingTouchBatch(at: 6))
        if await route.counters().droppedNotRunning > droppedWhileUnbound {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await route.counters().droppedNotRunning > droppedWhileUnbound)
    try await waitForBindingCondition {
        await middleInput.cancelAllAttempts() >= 2
    }
    let attemptsAfterFailure = await middleInput.sendAttempts
    await route.send(bindingTouchBatch(at: 7))
    #expect(await middleInput.sendAttempts == attemptsAfterFailure)
    #expect(await route.counters().droppedChannel > 0)

    await agent.loseSession()
    await agent.restoreSession(token: Data([3]), channel: newChannel)
    try await waitForBindingCondition {
        await newInput.batches.count == 1
    }
    await route.send(bindingTouchBatch(at: 8))
    try await waitForBindingCondition {
        await newInput.batches.count == 2
    }
    #expect(await oldInput.sendAttempts == attemptsAfterLoss)
    #expect(await middleInput.sendAttempts == attemptsAfterFailure)
    task.cancel()
    await task.value
}
