import Foundation
import GuestProtocol
import Testing

@testable import RuntimeCore

private actor GuestAgentStateRecorder {
    private(set) var states: [GuestAgentSupervisor.State] = []

    func append(_ state: GuestAgentSupervisor.State) {
        states.append(state)
    }
}

private actor RequiredAgentOutageCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

@Test(.timeLimit(.minutes(1)))
func guestAgentStateStreamPublishesTheCurrentStateAndReconnectTransitions() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request -> GPResponse.OneOf_Result? in
            switch request.op {
            case .getSnapshot?:
                return .getSnapshot(GPSnapshot())
            case .ping(let ping)?:
                var pong = GPPong()
                pong.nonce = ping.nonce
                return .ping(pong)
            default:
                return nil
            }
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in false }
    )
    try await supervisor.start(connectTimeout: .seconds(1))

    let recorder = GuestAgentStateRecorder()
    let updates = await supervisor.stateUpdates()
    let collector = Task {
        for await state in updates {
            await recorder.append(state)
            if state == .unavailable { return }
        }
    }

    transport.agents[0].hangUp()
    let deadline = ContinuousClock.now + .seconds(2)
    while await recorder.states.last != .unavailable, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await recorder.states == [.ready, .reconnecting, .unavailable])

    collector.cancel()
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func requiredAgentReadinessResetsTheOutageDeadline() async throws {
    let counter = RequiredAgentOutageCounter()
    let monitor = RequiredAgentOutageMonitor(timeout: .milliseconds(100)) {
        await counter.increment()
    }

    await monitor.observe(.reconnecting)
    try await Task.sleep(for: .milliseconds(60))
    await monitor.observe(.ready)
    try await Task.sleep(for: .milliseconds(60))
    #expect(await counter.count == 0)

    await monitor.observe(.unresponsive)
    try await Task.sleep(for: .milliseconds(60))
    #expect(await counter.count == 0)
    try await Task.sleep(for: .milliseconds(60))
    #expect(await counter.count == 1)

    await monitor.observe(.reconnecting)
    try await Task.sleep(for: .milliseconds(120))
    #expect(await counter.count == 1)
    await monitor.stop()
}

@Test(.timeLimit(.minutes(1)))
func stoppingTheOutageMonitorInvalidatesItsDeadline() async throws {
    let counter = RequiredAgentOutageCounter()
    let monitor = RequiredAgentOutageMonitor(timeout: .milliseconds(60)) {
        await counter.increment()
    }

    await monitor.observe(.reconnecting)
    await monitor.stop()
    try await Task.sleep(for: .milliseconds(100))

    #expect(await counter.count == 0)
}

@Test
func onlyAnExpiredRuntimeRequiredAgentDeadlineMapsToRequiredAgentUnavailable() {
    let now = ContinuousClock.now
    let expired = now - .milliseconds(1)
    let future = now + .seconds(1)

    #expect(
        RuntimeSupervisor.requiredAgentStartFailure(
            .connectTimedOut,
            deadline: expired,
            now: now
        ) == .requiredAgentUnavailable(agent: .guestAgent)
    )
    #expect(
        RuntimeSupervisor.requiredAgentStartFailure(
            .connectTimedOut,
            deadline: future,
            now: now
        ) == .guestAgent(.connectTimedOut)
    )
    #expect(
        RuntimeSupervisor.requiredAgentStartFailure(
            .startFailed,
            deadline: expired,
            now: now
        ) == .guestAgent(.startFailed)
    )

    let failure = RuntimeBootFailure.requiredAgentUnavailable(agent: .guestAgent)
    #expect(failure.qualifiedCode == "runtime.requiredAgentUnavailable")
    #expect(failure.parameters["agent"] == .text("Guest Agent"))
    #expect(GuestAgentFailure.requiredAgentUnavailable.parameters["agent"] == .text("Guest Agent"))
}
