import Foundation
import GuestProtocol
import Testing

@testable import RuntimeCore

private let reconnectTestPingNonce: UInt64 = 0xA9_01

private func reconnectTestTransport() -> InMemoryTransport {
    InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request in
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
}

private func reconnectTestContainsPing(_ agent: InMemoryAgent, nonce: UInt64) -> Bool {
    agent.requests.contains { request in
        guard case .ping(let ping)? = request.op else { return false }
        return ping.nonce == nonce
    }
}

private func waitForGuestAgentCondition(
    within duration: Duration = .seconds(2),
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + duration
    while await !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await condition())
}

private actor ReconnectHold {
    private var entered = false
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Test(.timeLimit(.minutes(1)))
func aRequestWaitsForResynchronisationAndIsSentOnce() async throws {
    let gate = ReconnectHold()
    let transport = reconnectTestTransport()
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        backoffMinimum: .milliseconds(10),
        backoffMaximum: .milliseconds(20),
        requestReconnectTimeout: .seconds(2),
        restartAgent: { _ in
            await gate.pause()
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(1))

    transport.agents[0].hangUp()
    try await waitForGuestAgentCondition { await supervisor.state == .reconnecting }
    await gate.waitUntilEntered()

    let request = Task {
        try await supervisor.send(GuestPing(nonce: reconnectTestPingNonce))
    }
    try await Task.sleep(for: .milliseconds(20))
    await gate.release()

    let response = try await request.value
    #expect(response.nonce == reconnectTestPingNonce)
    #expect(transport.agents.count == 2)
    #expect(!reconnectTestContainsPing(transport.agents[0], nonce: reconnectTestPingNonce))
    #expect(reconnectTestContainsPing(transport.agents[1], nonce: reconnectTestPingNonce))
    #expect(
        transport.agents[1].requests.filter {
            guard case .ping(let ping)? = $0.op else { return false }
            return ping.nonce == reconnectTestPingNonce
        }.count == 1)
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func aRequestTimesOutWhenReconnectDoesNotComplete() async throws {
    let transport = reconnectTestTransport()
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        backoffMinimum: .milliseconds(10),
        backoffMaximum: .milliseconds(20),
        requestReconnectTimeout: .milliseconds(100),
        restartAgent: { _ in true }
    )
    try await supervisor.start(connectTimeout: .seconds(1))

    transport.refuseNext(20)
    transport.agents[0].hangUp()
    try await waitForGuestAgentCondition { await supervisor.state == .reconnecting }
    let started = ContinuousClock.now

    do {
        _ = try await supervisor.send(GuestPing(nonce: reconnectTestPingNonce))
        Issue.record("the request succeeded without a connected Guest Agent")
    } catch {
        #expect(error == .agentUnavailable(kind: .guestAgent))
    }
    #expect(ContinuousClock.now - started >= .milliseconds(80))
    #expect(ContinuousClock.now - started < .seconds(1))
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func stoppingWakesRequestsWaitingForReconnect() async throws {
    let gate = ReconnectHold()
    let transport = reconnectTestTransport()
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        requestReconnectTimeout: .seconds(2),
        restartAgent: { _ in
            await gate.pause()
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(1))

    transport.agents[0].hangUp()
    try await waitForGuestAgentCondition { await supervisor.state == .reconnecting }
    await gate.waitUntilEntered()
    let request = Task {
        try await supervisor.send(GuestPing(nonce: reconnectTestPingNonce))
    }
    try await Task.sleep(for: .milliseconds(20))

    let stoppedAt = ContinuousClock.now
    await supervisor.stop()
    do {
        _ = try await request.value
        Issue.record("the request succeeded after the supervisor stopped")
    } catch {
        #expect((error as? GuestProtocolFailure) == .agentUnavailable(kind: .guestAgent))
    }
    #expect(ContinuousClock.now - stoppedAt < .milliseconds(500))
    await gate.release()
}

@Test(.timeLimit(.minutes(1)))
func cancellingARequestWakesItsReconnectWaitPromptly() async throws {
    let gate = ReconnectHold()
    let transport = reconnectTestTransport()
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        requestReconnectTimeout: .seconds(2),
        restartAgent: { _ in
            await gate.pause()
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(1))

    transport.agents[0].hangUp()
    try await waitForGuestAgentCondition { await supervisor.state == .reconnecting }
    await gate.waitUntilEntered()
    let request = Task {
        try await supervisor.send(GuestPing(nonce: reconnectTestPingNonce))
    }
    try await Task.sleep(for: .milliseconds(20))

    let cancelledAt = ContinuousClock.now
    request.cancel()
    do {
        _ = try await request.value
        Issue.record("the cancelled request succeeded")
    } catch {
        #expect((error as? GuestProtocolFailure) == .agentUnavailable(kind: .guestAgent))
    }
    #expect(ContinuousClock.now - cancelledAt < .milliseconds(500))
    await supervisor.stop()
    await gate.release()
}

@Test(.timeLimit(.minutes(1)))
func anInFlightRequestIsNotReplayedAfterDisconnect() async throws {
    let transport = InMemoryTransport { _, agent, number in
        agent.sendHello()
        agent.answer = { request in
            switch request.op {
            case .getSnapshot?:
                return .getSnapshot(GPSnapshot())
            case .ping(let ping)? where number == 1 && ping.nonce == reconnectTestPingNonce:
                return nil
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
        backoffMinimum: .milliseconds(10),
        backoffMaximum: .milliseconds(20),
        restartAgent: { _ in true }
    )
    try await supervisor.start(connectTimeout: .seconds(1))

    let request = Task {
        try await supervisor.send(GuestPing(nonce: reconnectTestPingNonce))
    }
    try await waitForGuestAgentCondition {
        reconnectTestContainsPing(transport.agents[0], nonce: reconnectTestPingNonce)
    }
    transport.agents[0].hangUp()

    do {
        _ = try await request.value
        Issue.record("the in-flight request succeeded without an answer")
    } catch {
        #expect((error as? GuestProtocolFailure) == .disconnected)
    }
    try await waitForGuestAgentCondition {
        await supervisor.state == .ready && transport.agents.count == 2
    }
    #expect(!reconnectTestContainsPing(transport.agents[1], nonce: reconnectTestPingNonce))
    await supervisor.stop()
}
