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
    private var duringNextUsabilityCheck: (@Sendable () async -> Void)?

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

    func disconnect() {
        isAlive = false
    }

    func usable() async -> Bool {
        if let action = duringNextUsabilityCheck {
            duringNextUsabilityCheck = nil
            await action()
        }
        return isAlive
    }

    func changeSessionDuringNextUsabilityCheck(_ action: @escaping @Sendable () async -> Void) {
        duringNextUsabilityCheck = action
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

    func touchAttempts() -> Int {
        attemptedBatches.filter { batch in
            batch.events.contains { event in
                if case .touch? = event.kind {
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
    private var tokenToSetDuringNextOpen: Data?

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

    func openInputChannel() async throws(GuestAgentFailure) -> DevInputBindingChannel {
        guard nextChannel < channels.count else {
            throw .operationFailed(reason: "disconnected")
        }
        let channel = channels[nextChannel]
        nextChannel += 1
        if let token = tokenToSetDuringNextOpen {
            tokenToSetDuringNextOpen = nil
            self.token = token
            continuation.yield(.ready)
        }
        return channel
    }

    func changeSessionDuringNextOpen(to token: Data) {
        tokenToSetDuringNextOpen = token
    }

    func changeSession(to token: Data) {
        self.token = token
        continuation.yield(.ready)
    }

    func changeSessionWithoutNotification(to token: Data) {
        self.token = token
    }

    func notifyReady() {
        continuation.yield(.ready)
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

private actor BindingUsabilityGate {
    private let entered: AsyncStream<Void>
    private let enteredContinuation: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        let entered = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.entered = entered.stream
        enteredContinuation = entered.continuation
        let released = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.released = released.stream
        releaseContinuation = released.continuation
    }

    func waitUntilEntered() async {
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
    }

    func blockUntilReleased() async {
        enteredContinuation.yield(())
        var iterator = released.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseContinuation.yield(())
        releaseContinuation.finish()
    }
}

@Test
func refusesToOpenTheRouteGateAfterItsActivationGenerationChanges() {
    let activation = DevInputRouteActivation()
    let candidateGeneration = activation.activationGeneration

    activation.deactivate()

    #expect(!activation.activate(ifUnchangedSince: candidateGeneration))
    #expect(!activation.allowsInput)
}

private actor BindingFocusProbe {
    private let agent: BindingAgentState
    private let route: DevInputRoute
    private var didChangeSession = false

    init(agent: BindingAgentState, route: DevInputRoute) {
        self.agent = agent
        self.route = route
    }

    func changeSessionAndSendWhileFocusIsSuspended() async {
        guard !didChangeSession else {
            return
        }
        didChangeSession = true
        await agent.changeSession(to: Data([2]))
        await route.send(bindingTouchBatch(at: 1))
    }
}

private actor BindingSessionTokenReadProbe {
    private var shouldObserveNextRead = false
    private var didObserveRead = false

    func arm() {
        shouldObserveNextRead = true
    }

    func sessionToken(from agent: BindingAgentState) async -> Data? {
        let token = await agent.sessionToken()
        if shouldObserveNextRead {
            shouldObserveNextRead = false
            didObserveRead = true
        }
        return token
    }

    func observedRead() -> Bool {
        didObserveRead
    }
}

private actor BindingWindowFocusProbe {
    private let route: DevInputRoute
    private var didChangeFocus = false

    init(route: DevInputRoute) {
        self.route = route
    }

    func loseFocusAndSendWhileFocusIsSuspended() async {
        guard !didChangeFocus else {
            return
        }
        didChangeFocus = true
        await route.focusChanged(false, generation: 2)
        await route.send(bindingTouchBatch(at: 1))
    }
}

private final class BindingReportState: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings = 0

    func record(_ event: DevBootEvent) {
        guard case .message(let message) = event, message.hasPrefix("input is bound to display") else {
            return
        }
        lock.withLock {
            bindings += 1
        }
    }

    var hasBound: Bool {
        boundCount > 0
    }

    var boundCount: Int {
        lock.withLock { bindings }
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
    let reports = BindingReportState()
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
    let task = Task { await binding.run { reports.record($0) } }
    defer { task.cancel() }

    try await waitForBindingCondition {
        await oldInput.batches.count == 1 && reports.boundCount == 1
    }
    await route.send(bindingTouchBatch(at: 1))
    try await waitForBindingCondition {
        await oldInput.batches.count == 2
    }

    let cancelAllAttemptsBeforeLoss = await oldInput.cancelAllAttempts()
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
    #expect(await oldInput.cancelAllAttempts() == cancelAllAttemptsBeforeLoss)
    let attemptsAfterLoss = await oldInput.sendAttempts
    await route.send(bindingTouchBatch(at: 3))
    #expect(await oldInput.sendAttempts == attemptsAfterLoss)

    await agent.restoreSession(token: Data([2]), channel: middleChannel)
    try await waitForBindingCondition {
        await middleInput.batches.count == 1 && reports.boundCount == 2
    }
    await route.send(bindingTouchBatch(at: 4))
    try await waitForBindingCondition {
        await middleInput.batches.count == 2
    }

    // An event already in flight when the input stream dies is recorded as a channel drop.
    let cancelAllAttemptsBeforeChannelLoss = await middleInput.cancelAllAttempts()
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
    #expect(await middleInput.cancelAllAttempts() == cancelAllAttemptsBeforeChannelLoss)
    let attemptsAfterFailure = await middleInput.sendAttempts
    await route.send(bindingTouchBatch(at: 7))
    #expect(await middleInput.sendAttempts == attemptsAfterFailure)
    #expect(await route.counters().droppedChannel > 0)

    await agent.loseSession()
    await agent.restoreSession(token: Data([3]), channel: newChannel)
    try await waitForBindingCondition {
        await newInput.batches.count == 1 && reports.boundCount == 3
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

@Test(.timeLimit(.minutes(1)))
func closedWindowRouteIsNotRegisteredAfterGuestAgentRebind() async throws {
    let oldInput = BindingInputChannel()
    let newInput = BindingInputChannel()
    let oldChannel = DevInputBindingChannel(
        input: oldInput,
        isUsable: { await oldInput.usable() }
    )
    let newChannel = DevInputBindingChannel(
        input: newInput,
        isUsable: { await newInput.usable() }
    )
    let agent = BindingAgentState(token: Data([1]), channels: [oldChannel])
    let closedRoute = DevInputRoute()
    await closedRoute.setDisplayID(3)
    let liveRoute = DevInputRoute()
    await liveRoute.setDisplayID(7)
    await liveRoute.focusChanged(true, generation: 1)
    let reports = BindingReportState()
    let binding = DevInputBinding(
        routes: [closedRoute, liveRoute],
        stateUpdates: { await agent.stateUpdates() },
        sessionToken: { await agent.sessionToken() },
        openInputChannel: { () async throws(GuestAgentFailure) -> DevInputBindingChannel in
            try await agent.openInputChannel()
        },
        focusDisplay: { _ in },
        adbShellInvocationCount: { 0 },
        logSink: nil
    )
    let task = Task { await binding.run { reports.record($0) } }
    defer { task.cancel() }

    try await waitForBindingCondition {
        await oldInput.batches.count == 2 && reports.boundCount == 1
    }
    #expect(await oldInput.batches.map(\.displayID) == [3, 7])
    let cancelAllAttemptsBeforeDisconnect = await oldInput.cancelAllAttempts()
    await oldInput.disconnect()
    await closedRoute.retire()
    #expect(!(await closedRoute.canBind()))
    #expect(await oldInput.cancelAllAttempts() == cancelAllAttemptsBeforeDisconnect)
    await agent.loseSession()
    await agent.restoreSession(token: Data([2]), channel: newChannel)

    try await waitForBindingCondition {
        await newInput.batches.count == 1 && reports.boundCount == 2
    }
    #expect(await newInput.batches.map(\.displayID) == [7])
    await closedRoute.send(bindingTouchBatch(at: 2))
    await liveRoute.send(bindingTouchBatch(at: 3))
    try await waitForBindingCondition {
        await newInput.batches.count == 2
    }
    #expect(await newInput.batches.map(\.displayID) == [7, 7])
    #expect(await closedRoute.counters().droppedNotRunning == 1)
    task.cancel()
    await task.value
}

@Test(.timeLimit(.minutes(1)))
func refusesToBindAnInputChannelWhenTheControlSessionChangesDuringUsabilityCheck() async throws {
    let staleInput = BindingInputChannel()
    let currentInput = BindingInputChannel()
    let staleChannel = DevInputBindingChannel(
        input: staleInput,
        isUsable: { await staleInput.usable() }
    )
    let currentChannel = DevInputBindingChannel(
        input: currentInput,
        isUsable: { await currentInput.usable() }
    )
    let agent = BindingAgentState(token: Data([1]), channels: [staleChannel, currentChannel])
    await staleInput.changeSessionDuringNextUsabilityCheck {
        await agent.changeSession(to: Data([2]))
    }
    let route = DevInputRoute()
    await route.focusChanged(true, generation: 1)
    let reports = BindingReportState()
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
    let task = Task { await binding.run { reports.record($0) } }
    defer { task.cancel() }

    try await waitForBindingCondition {
        await currentInput.batches.count == 1 && reports.boundCount == 1
    }
    #expect(await staleInput.sendAttempts == 0)
    await route.send(bindingTouchBatch(at: 1))
    try await waitForBindingCondition {
        await currentInput.batches.count == 2
    }
    #expect(await staleInput.sendAttempts == 0)
    task.cancel()
    await task.value
}

@Test(.timeLimit(.minutes(1)))
func keepsAStaleRouteInactiveWhileItsFocusIsBeingApplied() async throws {
    let staleInput = BindingInputChannel()
    let currentInput = BindingInputChannel()
    let staleChannel = DevInputBindingChannel(
        input: staleInput,
        isUsable: { await staleInput.usable() }
    )
    let currentChannel = DevInputBindingChannel(
        input: currentInput,
        isUsable: { await currentInput.usable() }
    )
    let agent = BindingAgentState(token: Data([1]), channels: [staleChannel, currentChannel])
    let route = DevInputRoute()
    await route.focusChanged(true, generation: 1)
    let reports = BindingReportState()
    let focusProbe = BindingFocusProbe(agent: agent, route: route)
    let binding = DevInputBinding(
        routes: [route],
        stateUpdates: { await agent.stateUpdates() },
        sessionToken: { await agent.sessionToken() },
        openInputChannel: { () async throws(GuestAgentFailure) -> DevInputBindingChannel in
            try await agent.openInputChannel()
        },
        focusDisplay: { _ in await focusProbe.changeSessionAndSendWhileFocusIsSuspended() },
        adbShellInvocationCount: { 0 },
        logSink: nil
    )
    let task = Task { await binding.run { reports.record($0) } }
    defer { task.cancel() }

    try await waitForBindingCondition {
        await currentInput.batches.count == 1 && reports.boundCount == 1
    }
    #expect(await staleInput.sendAttempts == 0)
    #expect(await route.counters().droppedNotRunning == 1)
    await route.send(bindingTouchBatch(at: 2))
    try await waitForBindingCondition {
        await currentInput.batches.count == 2
    }
    #expect(await staleInput.sendAttempts == 0)
    task.cancel()
    await task.value
}

@Test(.timeLimit(.minutes(1)))
func rechecksTheSessionAfterTheExistingInputChannelBecomesUsable() async throws {
    let oldInput = BindingInputChannel()
    let currentInput = BindingInputChannel()
    let tokenReads = BindingSessionTokenReadProbe()
    let oldChannel = DevInputBindingChannel(
        input: oldInput,
        isUsable: { await oldInput.usable() }
    )
    let currentChannel = DevInputBindingChannel(
        input: currentInput,
        isUsable: { await currentInput.usable() }
    )
    let agent = BindingAgentState(token: Data([1]), channels: [oldChannel, currentChannel])
    let route = DevInputRoute()
    await route.focusChanged(true, generation: 1)
    let reports = BindingReportState()
    let binding = DevInputBinding(
        routes: [route],
        stateUpdates: { await agent.stateUpdates() },
        sessionToken: { await tokenReads.sessionToken(from: agent) },
        openInputChannel: { () async throws(GuestAgentFailure) -> DevInputBindingChannel in
            try await agent.openInputChannel()
        },
        focusDisplay: { _ in },
        adbShellInvocationCount: { 0 },
        logSink: nil,
        pollInterval: .seconds(30)
    )
    let task = Task { await binding.run { reports.record($0) } }
    defer { task.cancel() }

    try await waitForBindingCondition {
        await oldInput.batches.count == 1 && reports.hasBound
    }
    let oldAttemptsBeforeSessionChange = await oldInput.sendAttempts
    await oldInput.changeSessionDuringNextUsabilityCheck {
        await agent.changeSessionWithoutNotification(to: Data([2]))
        await tokenReads.arm()
    }
    await agent.notifyReady()

    try await waitForBindingCondition {
        await tokenReads.observedRead()
    }
    let dropsBeforeDetach = await route.counters().droppedNotRunning
    let detachDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < detachDeadline {
        await route.send(bindingTouchBatch(at: 1))
        if await route.counters().droppedNotRunning > dropsBeforeDetach {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await route.counters().droppedNotRunning > dropsBeforeDetach)
    #expect(await oldInput.sendAttempts == oldAttemptsBeforeSessionChange)
    task.cancel()
    await task.value
}

@Test(.timeLimit(.minutes(1)))
func closesTheRouteGateAsSoonAsTheGuestAgentReportsLoss() async throws {
    let input = BindingInputChannel()
    let usabilityGate = BindingUsabilityGate()
    let channel = DevInputBindingChannel(
        input: input,
        isUsable: { await input.usable() }
    )
    let agent = BindingAgentState(token: Data([1]), channels: [channel])
    let route = DevInputRoute()
    await route.focusChanged(true, generation: 1)
    let reports = BindingReportState()
    let activation = DevInputRouteActivation()
    let binding = DevInputBinding(
        routes: [route],
        stateUpdates: { await agent.stateUpdates() },
        sessionToken: { await agent.sessionToken() },
        openInputChannel: { () async throws(GuestAgentFailure) -> DevInputBindingChannel in
            try await agent.openInputChannel()
        },
        focusDisplay: { _ in },
        adbShellInvocationCount: { 0 },
        logSink: nil,
        routeActivation: activation
    )
    let task = Task { await binding.run { reports.record($0) } }
    defer { task.cancel() }
    try await waitForBindingCondition {
        reports.boundCount == 1
    }
    let touchAttemptsBeforeLoss = await input.touchAttempts()
    await input.changeSessionDuringNextUsabilityCheck {
        await usabilityGate.blockUntilReleased()
    }
    await agent.notifyReady()
    await usabilityGate.waitUntilEntered()
    await agent.loseSession()
    try await waitForBindingCondition {
        !activation.allowsInput
    }

    await route.send(bindingTouchBatch(at: 1))
    #expect(await input.touchAttempts() == touchAttemptsBeforeLoss)
    #expect(await route.counters().droppedNotRunning == 1)
    await usabilityGate.release()
    task.cancel()
    await task.value
}

@Test(.timeLimit(.minutes(1)))
func appliesFocusChangesWhileTheRouteIsPreparedBeforeAcceptingInput() async throws {
    let input = BindingInputChannel()
    let channel = DevInputBindingChannel(
        input: input,
        isUsable: { await input.usable() }
    )
    let agent = BindingAgentState(token: Data([1]), channels: [channel])
    let route = DevInputRoute()
    await route.focusChanged(true, generation: 1)
    let focusProbe = BindingWindowFocusProbe(route: route)
    let reports = BindingReportState()
    let binding = DevInputBinding(
        routes: [route],
        stateUpdates: { await agent.stateUpdates() },
        sessionToken: { await agent.sessionToken() },
        openInputChannel: { () async throws(GuestAgentFailure) -> DevInputBindingChannel in
            try await agent.openInputChannel()
        },
        focusDisplay: { _ in await focusProbe.loseFocusAndSendWhileFocusIsSuspended() },
        adbShellInvocationCount: { 0 },
        logSink: nil
    )
    let task = Task { await binding.run { reports.record($0) } }
    defer { task.cancel() }

    try await waitForBindingCondition {
        reports.hasBound
    }
    #expect(await route.counters().droppedNotRunning == 1)
    let attemptsBeforeUnfocusedInput = await input.sendAttempts
    await route.send(bindingTouchBatch(at: 2))
    try await waitForBindingCondition {
        await route.counters().droppedNotFocused == 1
    }
    #expect(await input.sendAttempts == attemptsBeforeUnfocusedInput)
    task.cancel()
    await task.value
}

@Test(.timeLimit(.minutes(1)))
func closesTheRouteGateBeforeCheckingTheInputChannelOnShutdown() async throws {
    let input = BindingInputChannel()
    let channel = DevInputBindingChannel(
        input: input,
        isUsable: { await input.usable() }
    )
    let agent = BindingAgentState(token: Data([1]), channels: [channel])
    let route = DevInputRoute()
    await route.focusChanged(true, generation: 1)
    let reports = BindingReportState()
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
    let task = Task { await binding.run { reports.record($0) } }
    try await waitForBindingCondition {
        reports.boundCount == 1
    }
    await input.changeSessionDuringNextUsabilityCheck {
        await route.send(bindingTouchBatch(at: 1))
    }

    task.cancel()
    await task.value
    #expect(await input.touchAttempts() == 0)
    #expect(await route.counters().droppedNotRunning == 1)
}
