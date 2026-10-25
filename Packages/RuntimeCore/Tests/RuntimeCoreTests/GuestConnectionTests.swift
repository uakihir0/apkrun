import Foundation
import GuestProtocol
import Testing

@testable import RuntimeCore

/// The handshake and the request rules of `GuestConnection`, run against an in-memory agent (guest-protocol.md
/// §5, §6, §12; #73 T0).

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
    let transport = GatedHandshakeAckTransport()
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    do {
        _ = try await connection.open()
        Issue.record("an input agent was accepted on the control channel")
    } catch {
        #expect(error == .handshakeFailed(.wrongChannel))
    }
    try await eventually {
        transport.stream?.didBlockRejectedAck == true
    }
    let closeTask = Task { await connection.close() }
    let closeDeadline = ContinuousClock.now + .seconds(5)
    while !(await connection.isCloseRequested), ContinuousClock.now < closeDeadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await connection.isCloseRequested)
    transport.stream?.releaseRejectedAck()
    await closeTask.value

    let rejection = transport.agent.envelopes.compactMap { envelope -> GPRejected? in
        if case .helloAck(let ack)? = envelope.body, case .rejected(let rejected)? = ack.outcome {
            return rejected
        }
        return nil
    }
    #expect(rejection.first?.reason == .wrongChannel)
    #expect(transport.stream?.closeCount == 1)
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
func taskHealthAndShutdownOperationsRoundTripOnTheControlConnection() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.answer = { request in
            guard let operation = request.op else { return nil }
            switch operation {
            case .moveTaskToDisplay:
                return .moveTaskToDisplay(GPEmpty())
            case .listTasks:
                var task = GPTaskInfo()
                task.taskID = 27
                task.displayID = 4
                task.package = "io.apkrun.example"
                var tasks = GPTaskList()
                tasks.tasks = [task]
                return .listTasks(tasks)
            case .getHealth:
                var health = GPHealth()
                health.displaysCount = 2
                return .getHealth(health)
            case .shutdown:
                return .shutdown(GPEmpty())
            default:
                return nil
            }
        }
        agent.sendHello(capabilities: ["core.v1", "launch.v1", "health.v1", "system.v1"])
    }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()

    _ = try await connection.send(GuestMoveTaskToDisplay(taskID: 27, displayID: 4, toBack: true))
    let tasks = try await connection.send(GuestListTasks(displayID: 4))
    let health = try await connection.send(GuestGetHealth())
    _ = try await connection.send(GuestShutdown(reason: "test complete"))

    #expect(tasks.tasks.map(\.taskID) == [27])
    #expect(tasks.tasks.first?.displayID == 4)
    #expect(health.displaysCount == 2)
    #expect(transport.agents[0].requests.count == 4)
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func taskHealthAndShutdownOperationsRequireTheirNegotiatedCapabilities() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello(capabilities: ["core.v1"])
    }
    let connection = GuestConnection(endpoint: .guestControl, transport: transport)
    _ = try await connection.open()

    do {
        _ = try await connection.send(GuestMoveTaskToDisplay(taskID: 1, displayID: 0))
        Issue.record("MoveTaskToDisplay was sent without launch.v1")
    } catch {
        #expect(error == .capabilityMissing(capability: "launch.v1"))
    }
    do {
        _ = try await connection.send(GuestGetHealth())
        Issue.record("GetHealth was sent without health.v1")
    } catch {
        #expect(error == .capabilityMissing(capability: "health.v1"))
    }
    do {
        _ = try await connection.send(GuestShutdown(reason: "test"))
        Issue.record("Shutdown was sent without system.v1")
    } catch {
        #expect(error == .capabilityMissing(capability: "system.v1"))
    }

    #expect(transport.agents[0].requests.isEmpty)
    await connection.close()
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

@Test(.timeLimit(.minutes(1)))
func storeArtifactConnectionSendsAndReceivesBulkFramesWithBackpressure() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello(capabilities: ["store.install.v1", "store.metadata.v1"])
    }
    let connection = GuestConnection(
        endpoint: .storeArtifacts,
        transport: transport,
        presentedToken: Data(repeating: 7, count: 16)
    )
    _ = try await connection.open()

    var begin = GPBulkBegin()
    begin.kind = .installArtifact
    begin.name = "base"
    begin.mimeType = "application/vnd.android.package-archive"
    begin.size = 3
    begin.sha256 = Data(repeating: 9, count: 32)
    begin.context = "install-1"
    var outgoing = GPBulkFrame()
    outgoing.transferID = 2
    outgoing.kind = .begin(begin)
    try await connection.sendBulkFrame(outgoing)

    try await eventually {
        transport.agents[0].envelopes.contains { envelope in
            guard case .bulk(let frame)? = envelope.body,
                case .begin(let received)? = frame.kind
            else {
                return false
            }
            return frame.transferID == 2 && received.context == "install-1"
        }
    }

    let receivedFrame = Task { () -> GPBulkFrame? in
        for await frame in connection.bulkFrames {
            return frame
        }
        return nil
    }
    var ack = GPBulkAck()
    ack.status = .ok
    var incoming = GPBulkFrame()
    incoming.transferID = 2
    incoming.kind = .ack(ack)
    transport.agents[0].sendBulkFrame(incoming)
    let decoded = await receivedFrame.value
    #expect(decoded?.transferID == 2)
    if case .ack(let value)? = decoded?.kind {
        #expect(value.status == .ok)
    } else {
        Issue.record("the artifact stream did not deliver its bulk acknowledgement")
    }
    await connection.close()
}

@Test(.timeLimit(.minutes(1)))
func bulkFrameWriteTimeoutClosesAStalledTransport() async throws {
    let transport = BlockingBulkWriteTransport()
    let connection = GuestConnection(
        endpoint: .storeArtifacts,
        transport: transport,
        presentedToken: Data(repeating: 7, count: 16)
    )
    _ = try await connection.open()

    var begin = GPBulkBegin()
    begin.kind = .installArtifact
    begin.name = "base"
    begin.mimeType = "application/vnd.android.package-archive"
    begin.size = 1
    begin.sha256 = Data(repeating: 9, count: 32)
    begin.context = "install-1"
    var outgoing = GPBulkFrame()
    outgoing.transferID = 2
    outgoing.kind = .begin(begin)

    do {
        try await connection.sendBulkFrame(outgoing, timeout: .milliseconds(100))
        Issue.record("a stalled bulk frame write did not time out")
    } catch {
        #expect(error == GuestProtocolFailure.timeout(operation: "bulk frame write"))
    }

    #expect(await connection.closeReason == .timeout(operation: "bulk frame write"))
    try await eventually {
        transport.stream?.closeCount == 1
    }
    #expect(transport.stream?.closeCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func closingConnectionForcesAStalledWriterAfterDrainDeadline() async throws {
    let transport = BlockingBulkWriteTransport()
    let connection = GuestConnection(
        endpoint: .storeArtifacts,
        transport: transport,
        presentedToken: Data(repeating: 7, count: 16)
    )
    _ = try await connection.open()

    var begin = GPBulkBegin()
    begin.kind = .installArtifact
    begin.name = "base"
    begin.mimeType = "application/vnd.android.package-archive"
    begin.size = 1
    begin.sha256 = Data(repeating: 9, count: 32)
    begin.context = "install-1"
    var outgoing = GPBulkFrame()
    outgoing.transferID = 2
    outgoing.kind = .begin(begin)

    let send = Task { try? await connection.sendBulkFrame(outgoing) }
    try await eventually {
        transport.stream?.didBlockBulkWrite == true
    }

    await connection.close()
    await send.value

    #expect(await connection.closeReason == .disconnected)
    #expect(transport.stream?.closeCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func bulkFramesAreRejectedOnControlEndpoints() async throws {
    let connection = GuestConnection(
        endpoint: .storeControl,
        transport: InMemoryTransport { _, agent, _ in
            agent.sendHello(capabilities: ["store.install.v1"])
        }
    )
    _ = try await connection.open()
    do {
        try await connection.sendBulkFrame(GPBulkFrame())
        Issue.record("a control connection accepted a bulk frame")
    } catch {
        #expect(error == .malformedFrame)
    }
    await connection.close()
}

private final class GatedHandshakeAckTransport: GuestTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let backing: InMemoryTransport
    private var openedStream: GatedHandshakeAckStream?

    init() {
        backing = InMemoryTransport { _, agent, _ in agent.sendHello(channel: .guestInput) }
    }

    var agent: InMemoryAgent {
        backing.agents[0]
    }

    var stream: GatedHandshakeAckStream? {
        lock.withLock { openedStream }
    }

    func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream {
        let base = try await backing.open(endpoint)
        let stream = GatedHandshakeAckStream(base: base)
        lock.withLock { openedStream = stream }
        return stream
    }
}

private final class GatedHandshakeAckStream: GuestByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private let base: any GuestByteStream
    private var isClosed = false
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var didBlockRejectedAckStorage = false
    private var closeCountStorage = 0

    init(base: any GuestByteStream) {
        self.base = base
    }

    var didBlockRejectedAck: Bool {
        lock.withLock { didBlockRejectedAckStorage }
    }

    var closeCount: Int {
        lock.withLock { closeCountStorage }
    }

    func read() async throws -> Data? {
        try await base.read()
    }

    func write(_ bytes: Data) async throws {
        let envelope = try FrameCodec.decode(bytes)
        guard case .helloAck(let ack)? = envelope.body,
            case .rejected(let rejected)? = ack.outcome,
            rejected.reason == .wrongChannel
        else {
            try await base.write(bytes)
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let shouldWait = lock.withLock {
                guard !isClosed else {
                    return false
                }
                didBlockRejectedAckStorage = true
                pendingWrite = continuation
                return true
            }
            if !shouldWait {
                continuation.resume(throwing: CancellationError())
            }
        }
        try await base.write(bytes)
    }

    func releaseRejectedAck() {
        let pending = lock.withLock {
            let pending = pendingWrite
            pendingWrite = nil
            return pending
        }
        pending?.resume()
    }

    func close() async {
        let pending = lock.withLock {
            closeCountStorage += 1
            isClosed = true
            let pending = pendingWrite
            pendingWrite = nil
            return pending
        }
        pending?.resume(throwing: CancellationError())
        await base.close()
    }
}

private final class BlockingBulkWriteTransport: GuestTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var openedStream: BlockingBulkWriteStream?
    private let agent = InMemoryTransport { _, agent, _ in
        agent.sendHello(channel: .storeArtifacts, capabilities: ["store.install.v1"])
    }

    var stream: BlockingBulkWriteStream? {
        lock.withLock { openedStream }
    }

    func open(_ endpoint: GuestEndpoint) async throws -> any GuestByteStream {
        let base = try await agent.open(endpoint)
        let stream = BlockingBulkWriteStream(base: base)
        lock.withLock { openedStream = stream }
        return stream
    }
}

private final class BlockingBulkWriteStream: GuestByteStream, @unchecked Sendable {
    private let lock = NSLock()
    private let base: any GuestByteStream
    private var isClosed = false
    private var didBlockBulkWriteStorage = false
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var closeCountStorage = 0

    init(base: any GuestByteStream) {
        self.base = base
    }

    var closeCount: Int {
        lock.withLock { closeCountStorage }
    }

    var didBlockBulkWrite: Bool {
        lock.withLock { didBlockBulkWriteStorage }
    }

    func read() async throws -> Data? {
        return try await base.read()
    }

    func write(_ bytes: Data) async throws {
        let envelope = try FrameCodec.decode(bytes)
        if case .bulk? = envelope.body {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let shouldWait = lock.withLock {
                    guard !isClosed, !didBlockBulkWriteStorage else {
                        return false
                    }
                    didBlockBulkWriteStorage = true
                    pendingWrite = continuation
                    return true
                }
                if !shouldWait {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
        try await base.write(bytes)
    }

    func close() async {
        let pending = lock.withLock {
            closeCountStorage += 1
            isClosed = true
            let pending = pendingWrite
            pendingWrite = nil
            return pending
        }
        pending?.resume(throwing: CancellationError())
        await base.close()
    }
}
