import Foundation
import GuestProtocol
import Testing

@testable import RuntimeCore

/// The handshake and the request rules of `GuestConnection`, run against an in-memory agent (guest-protocol.md
/// §5, §6, §12; #072 T0).

/// Waits until `condition` holds, up to `seconds`. Used where the test must observe a state that another task reaches.
private func eventually(within seconds: Double = 5, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func removedDisplay(_ id: Int32) -> GPEvent.OneOf_Kind {
    var removed = GPDisplayRemoved()
    removed.displayID = id
    return .displayRemoved(removed)
}

private func pong(_ nonce: UInt64) -> GPResponse.OneOf_Result {
    var pong = GPPong()
    pong.nonce = nonce
    return .ping(pong)
}

private func nonce(of request: GPRequest) -> UInt64 {
    if case .ping(let ping)? = request.op {
        return ping.nonce
    }
    return 0
}

/// An agent that says hello and answers pings at once.
private func answeringAgent(_ endpoint: GuestEndpoint, _ agent: InMemoryAgent, _ number: Int) {
    agent.answer = { request in
        if case .ping = request.op {
            return pong(nonce(of: request))
        }
        return nil
    }
    agent.sendHello()
}

@Test(.timeLimit(.minutes(1)))
func handshakeAcceptsAMatchingAgentAndMakesTheSessionToken() async throws {
    let transport = InMemoryTransport(configure: answeringAgent)
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    let info = try await connection.open()
    #expect(info.enabledCapabilities == ["core.v1", "display.v1", "input.v1", "launch.v1"])
    #expect(info.sessionToken.count == 16)
    #expect(info.agentProtocolVersion == ProtocolVersion(major: 1, minor: 0))
    let ack = transport.agents[0].envelopes.first { envelope in
        if case .helloAck? = envelope.body { return true }
        return false
    }
    guard case .helloAck(let helloAck)? = ack?.body else {
        Issue.record("the host did not answer with HelloAck")
        return
    }
    #expect(helloAck.outcome == .accepted(GPAccepted()))
    #expect(helloAck.sessionToken == info.sessionToken)
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func handshakeRefusesAnotherMajorVersionAndSaysSo() async throws {
    let transport = InMemoryTransport { _, agent, _ in agent.sendHello(major: 2) }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    do {
        _ = try await connection.open()
        Issue.record("a major 2 agent was accepted")
    } catch {
        guard case .incompatibleVersion = error else {
            Issue.record("expected incompatibleVersion, got \(error)")
            return
        }
    }
    try await eventually {
        transport.agents[0].envelopes.contains { envelope in
            if case .helloAck? = envelope.body { return true }
            return false
        }
    }
    let rejection = transport.agents[0].envelopes.compactMap { envelope -> GPRejected? in
        if case .helloAck(let ack)? = envelope.body, case .rejected(let rejected)? = ack.outcome {
            return rejected
        }
        return nil
    }
    #expect(rejection.first?.reason == .incompatibleVersion)
}

@Test(.timeLimit(.minutes(1)))
func handshakeRefusesTheWrongChannel() async throws {
    let transport = InMemoryTransport { _, agent, _ in agent.sendHello(channel: .guestInput) }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    do {
        _ = try await connection.open()
        Issue.record("an input agent was accepted on the control channel")
    } catch {
        #expect(error == .handshakeFailed(.wrongChannel))
    }
}

@Test(.timeLimit(.minutes(1)))
func aSecondaryConnectionMustPresentTheControlToken() async throws {
    let connection = GuestConnection(
        endpoint: .guestInput,
        transport: InMemoryTransport(configure: answeringAgent)
    )
    do {
        _ = try await connection.open()
        Issue.record("a secondary connection opened without a token")
    } catch {
        #expect(error == .handshakeFailed(.badToken))
    }
}

@Test(.timeLimit(.minutes(1)))
func aSilentAgentFailsTheHandshakeAfterTheTimeout() async throws {
    let connection = GuestConnection(
        endpoint: .guestControl,
        transport: InMemoryTransport { _, _, _ in },
        handshakeTimeout: .milliseconds(50)
    )
    do {
        _ = try await connection.open()
        Issue.record("the handshake finished without a Hello")
    } catch {
        #expect(error == .handshakeTimedOut)
    }
}

@Test(.timeLimit(.minutes(1)))
func pipelinedRequestsGetTheirOwnAnswersWhenTheyArriveOutOfOrder() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
    }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    let agent = transport.agents[0]

    async let first = connection.send(GuestPing(nonce: 1))
    async let second = connection.send(GuestPing(nonce: 2))
    async let third = connection.send(GuestPing(nonce: 3))
    try await eventually { agent.heldCount == 3 }
    agent.releaseHeld(reversed: true) { request in pong(nonce(of: request)) }

    let answers = try await [first, second, third]
    #expect(answers.map(\.nonce) == [1, 2, 3])
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func aRequestPastItsDeadlineTimesOutAndTheConnectionStaysOpen() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request in
            if case .ping = request.op, nonce(of: request) == 2 {
                return pong(2)
            }
            return nil
        }
    }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    do {
        _ = try await connection.send(GuestPing(nonce: 1), timeout: .milliseconds(10))
        Issue.record("a request without an answer did not time out")
    } catch {
        #expect(error == .timeout(operation: "Ping"))
    }
    let usableAfterTimeout = await connection.isUsable
    #expect(usableAfterTimeout)
    let answer = try await connection.send(GuestPing(nonce: 2))
    #expect(answer.nonce == 2)
    transport.agents[0].releaseOldest { request in pong(nonce(of: request)) }
    let usableAtEnd = await connection.isUsable
    #expect(usableAtEnd)
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func aCancelledCallSendsCancelAndTheAgentsAnswerComesBack() async throws {
    let transport = InMemoryTransport { _, agent, _ in agent.sendHello() }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    let agent = transport.agents[0]
    let call = Task { try await connection.send(GuestPing(nonce: 7)) }
    try await eventually { agent.heldCount == 1 }
    call.cancel()
    try await eventually {
        agent.envelopes.contains {
            if case .cancel? = $0.body { return true }
            return false
        }
    }
    agent.releaseHeld(reversed: false) { _ in
        var error = GPGuestError()
        error.code = .cancelled
        error.message = "cancelled"
        return .error(error)
    }
    do {
        _ = try await call.value
        Issue.record("the cancelled call returned a value")
    } catch {
        guard let failure = error as? GuestProtocolFailure, case .remote(let code, _, _) = failure else {
            Issue.record("expected the agent's CANCELLED, got \(error)")
            return
        }
        #expect(code == .cancelled)
    }
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func anAgentErrorBecomesARemoteFailureWithItsCode() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { _ in
            var error = GPGuestError()
            error.code = .notFound
            error.message = "no such package"
            return .error(error)
        }
    }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    do {
        _ = try await connection.send(GuestPing(nonce: 1))
        Issue.record("an error answer returned a value")
    } catch {
        guard case .remote(let code, let message, let operation) = error else {
            Issue.record("expected remote, got \(error)")
            return
        }
        #expect(code == .notFound)
        #expect(message == "no such package")
        #expect(operation == "Ping")
    }
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func aGapInTheEventSequenceClosesTheConnection() async throws {
    let transport = InMemoryTransport { _, agent, _ in agent.sendHello() }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    let agent = transport.agents[0]
    let reader = Task {
        var seen: [UInt64] = []
        for await event in connection.events {
            seen.append(event.seq)
        }
        return seen
    }
    agent.sendEvent(seq: 1, removedDisplay(4))
    agent.sendEvent(seq: 3, removedDisplay(5))
    let seen = await reader.value
    #expect(seen == [1])
    let usable = await connection.isUsable
    #expect(!usable)
}

@Test(.timeLimit(.minutes(1)))
func aSixtyFifthRequestWaitsForASlot() async throws {
    let transport = InMemoryTransport { _, agent, _ in agent.sendHello() }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    let agent = transport.agents[0]
    var calls: [Task<UInt64, Error>] = []
    for nonce in 1...65 {
        calls.append(
            Task { try await connection.send(GuestPing(nonce: UInt64(nonce))).nonce }
        )
    }
    try await eventually { agent.requests.count == GuestConnection.maximumInFlight }
    try await Task.sleep(for: .milliseconds(100))
    #expect(agent.requests.count == GuestConnection.maximumInFlight)

    agent.releaseOldest { request in pong(nonce(of: request)) }
    try await eventually { agent.requests.count == 65 }
    agent.releaseHeld(reversed: false) { request in pong(nonce(of: request)) }
    var answered: [UInt64] = []
    for call in calls {
        answered.append(try await call.value)
    }
    #expect(answered.count == 65)
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func closingFailsThePendingRequests() async throws {
    let transport = InMemoryTransport { _, agent, _ in agent.sendHello() }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    let call = Task { try await connection.send(GuestPing(nonce: 1)) }
    try await eventually { transport.agents[0].heldCount == 1 }
    await connection.close()
    do {
        _ = try await call.value
        Issue.record("a closed connection returned a result")
    } catch {
        #expect((error as? GuestProtocolFailure) == .disconnected)
    }
}

@Test(.timeLimit(.minutes(1)))
func aTransportThatNeverOpensFailsTheHandshakeAtTheTimeout() async throws {
    let connection = GuestConnection(
        endpoint: .guestControl,
        transport: StalledTransport(),
        handshakeTimeout: .milliseconds(50)
    )
    let started = ContinuousClock.now
    do {
        _ = try await connection.open()
        Issue.record("a transport that never opened produced a session")
    } catch {
        #expect(error == .handshakeTimedOut)
    }
    #expect(ContinuousClock.now - started < .seconds(3))
}

@Test(.timeLimit(.minutes(1)))
func aCapabilityTheAgentDidNotEnableIsAnErrorBeforeTheRequestIsSent() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello(capabilities: ["core.v1"])
    }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    do {
        _ = try await connection.send(GuestLaunchApplication(package: "io.apkrun.example", displayID: 0))
        Issue.record("a launch went out although the agent did not enable launch.v1")
    } catch {
        #expect(error == .capabilityMissing(capability: "launch.v1"))
    }
    let sent = transport.agents[0].requests
    #expect(
        !sent.contains { request in
            if case .launchApplication? = request.op { return true }
            return false
        })
}

@Test(.timeLimit(.minutes(1)))
func anInputAckOnTheControlChannelIsAViolation() async throws {
    let transport = InMemoryTransport { _, agent, _ in agent.sendHello() }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()
    transport.agents[0].sendInputAck()
    var reason: GuestProtocolFailure?
    for _ in 0..<500 {
        reason = await connection.closeReason
        if reason != nil {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(reason == .malformedFrame)
}
