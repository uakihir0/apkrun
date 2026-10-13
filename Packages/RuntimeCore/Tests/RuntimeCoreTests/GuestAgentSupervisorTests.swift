import DiagnosticsCore
import Foundation
import GuestProtocol
import InputCore
import Testing

@testable import RuntimeCore

/// The supervisor's resync, keepalive, and recovery, run against in-memory agents (guest-protocol.md §6,
/// guest-components.md §3.3; #072 T0).

private func eventually(within seconds: Double = 8, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while await !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func display(_ id: Int32) -> GPDisplayInfo {
    var info = GPDisplayInfo()
    info.displayID = id
    info.uniqueID = "display-\(id)"
    return info
}

private func snapshot(displays: [Int32]) -> GPSnapshot {
    var snapshot = GPSnapshot()
    snapshot.displays = displays.map(display)
    return snapshot
}

private func isGetSnapshot(_ request: GPRequest) -> Bool {
    if case .getSnapshot? = request.op {
        return true
    }
    return false
}

private func isPing(_ request: GPRequest) -> Bool {
    if case .ping? = request.op {
        return true
    }
    return false
}

private func pongResult(for request: GPRequest) -> GPResponse.OneOf_Result? {
    guard case .ping(let ping)? = request.op else {
        return nil
    }
    var pong = GPPong()
    pong.nonce = ping.nonce
    return .ping(pong)
}

/// The recorder of restart calls, which the supervisor's closure reports to.
private final class LossLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GuestAgentLoss] = []

    func record(_ loss: GuestAgentLoss) {
        lock.withLock { values.append(loss) }
    }

    var all: [GuestAgentLoss] {
        lock.withLock { values }
    }
}

@Test(.timeLimit(.minutes(1)))
func startResyncsWithGetSnapshotBeforeAnythingElse() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request in
            isGetSnapshot(request) ? .getSnapshot(snapshot(displays: [0])) : pongResult(for: request)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in false }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    let state = await supervisor.state
    #expect(state == .ready)
    let displays = await supervisor.snapshot.displays.keys.sorted()
    #expect(displays == [0])
    let first = transport.agents[0].requests.first
    #expect(first.map(isGetSnapshot) == true)
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func eventsSentBeforeTheSnapshotAnswerAreAppliedAfterIt() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request in
            if isGetSnapshot(request) {
                // The agent changes state while it answers, so the events go out before the snapshot.
                agent.sendEvent(.displayAdded(display(5)))
                var task = GPTaskInfo()
                task.taskID = 9
                task.displayID = 5
                agent.sendEvent(.taskAppeared(task))
                return .getSnapshot(snapshot(displays: [0]))
            }
            return pongResult(for: request)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in false }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    let displays = await supervisor.snapshot.displays.keys.sorted()
    #expect(displays == [0, 5])
    let tasks = await supervisor.snapshot.tasks.keys.sorted()
    #expect(tasks == [9])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func aSilentAgentIsMarkedUnresponsiveAndRestarted() async throws {
    let losses = LossLog()
    let transport = InMemoryTransport { _, agent, number in
        agent.sendHello()
        agent.answer = { request in
            if isGetSnapshot(request) {
                return .getSnapshot(snapshot(displays: [0]))
            }
            // The first agent never answers a ping. The second one answers all of them.
            return number == 1 ? nil : pongResult(for: request)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .milliseconds(20),
        pingTimeout: .milliseconds(10),
        missLimit: 2,
        restartAgent: { loss in
            losses.record(loss)
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    try await eventually {
        await supervisor.state == .ready && transport.agents.count >= 2
            && transport.agents[1].requests.contains(where: isPing)
    }
    #expect(losses.all == [.unresponsive])
    #expect(transport.agents.count >= 2)
    #expect(transport.agents[1].requests.contains(where: isPing))
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func aClosedConnectionIsReconnectedAndResynchronised() async throws {
    let losses = LossLog()
    let transport = InMemoryTransport { _, agent, number in
        agent.sendHello()
        agent.answer = { request in
            if isGetSnapshot(request) {
                return .getSnapshot(snapshot(displays: [number == 1 ? 0 : 3]))
            }
            return pongResult(for: request)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { loss in
            losses.record(loss)
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    transport.agents[0].hangUp()
    try await eventually { await supervisor.state == .ready && transport.agents.count >= 2 }
    #expect(losses.all == [.disconnected])
    let displays = await supervisor.snapshot.displays.keys.sorted()
    #expect(displays == [3])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func aRefusedRestartEndsTheSupervisorUnavailable() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request in
            isGetSnapshot(request) ? .getSnapshot(snapshot(displays: [0])) : nil
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in false }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    transport.agents[0].hangUp()
    try await eventually { await supervisor.state == .unavailable }
    let state = await supervisor.state
    #expect(state == .unavailable)
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func aConnectionThatNeverComesUpTimesOut() async throws {
    let transport = InMemoryTransport { _, _, _ in }
    transport.refuseNext(100_000)
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in false }
    )
    do {
        try await supervisor.start(connectTimeout: .milliseconds(200))
        Issue.record("the supervisor connected to an agent that never answered")
    } catch {
        #expect(error == .connectTimedOut)
    }
}

private func displayRemovedEvent(_ id: Int32) -> GPEvent.OneOf_Kind {
    var removed = GPDisplayRemoved()
    removed.displayID = id
    return .displayRemoved(removed)
}

@Test(.timeLimit(.minutes(1)))
func aRefusedVersionFailsTheStartAtOnce() async throws {
    let transport = InMemoryTransport { _, agent, _ in agent.sendHello(major: 2) }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in true }
    )
    let started = ContinuousClock.now
    do {
        try await supervisor.start(connectTimeout: .seconds(10))
        Issue.record("the supervisor started with an agent of another major version")
    } catch {
        #expect(error == .handshakeFailed(reason: "incompatibleVersion"))
    }
    #expect(ContinuousClock.now - started < .seconds(3))
    #expect(transport.agents.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func aTransportThatNeverOpensFailsTheStartAtTheConnectDeadline() async throws {
    let supervisor = GuestAgentSupervisor(
        transport: StalledTransport(),
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in false }
    )
    let started = ContinuousClock.now
    do {
        try await supervisor.start(connectTimeout: .milliseconds(300))
        Issue.record("the supervisor connected through a transport that never opened")
    } catch {
        #expect(error == .connectTimedOut)
    }
    #expect(ContinuousClock.now - started < .seconds(3))
}

@Test(.timeLimit(.minutes(1)))
func aStopDuringTheStartEndsTheStartAsStopped() async throws {
    let inner = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request in
            isGetSnapshot(request) ? .getSnapshot(snapshot(displays: [0])) : pongResult(for: request)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: DelayedTransport(inner: inner, delay: .milliseconds(200)),
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in false }
    )
    let start = Task { try await supervisor.start(connectTimeout: .seconds(5)) }
    try await Task.sleep(for: .milliseconds(50))
    await supervisor.stop()
    do {
        try await start.value
        Issue.record("the start finished after the supervisor was stopped")
    } catch let failure as GuestAgentFailure {
        #expect(failure == .stopped)
    }
    let state = await supervisor.state
    #expect(state == .stopped)
}

@Test(.timeLimit(.minutes(1)))
func aRestartedAgentThatDiesBeforeItConnectsIsRestartedAgain() async throws {
    let losses = LossLog()
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request in
            isGetSnapshot(request) ? .getSnapshot(snapshot(displays: [0])) : pongResult(for: request)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        backoffMinimum: .milliseconds(10),
        backoffMaximum: .milliseconds(20),
        restartAgent: { loss in
            losses.record(loss)
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    // The restarted agent does not come up for two attempts, so each failed attempt asks for a restart again.
    transport.refuseNext(2)
    transport.agents[0].hangUp()
    try await eventually { await supervisor.state == .ready && transport.agents.count >= 2 }
    #expect(losses.all == [.disconnected, .disconnected, .disconnected])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func fiveProtocolViolationsStopTheReconnection() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        // A gap in the event sequence is a protocol violation (guest-protocol.md §12.2).
        agent.sendEvent(seq: 5, displayRemovedEvent(3))
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        backoffMinimum: .milliseconds(10),
        backoffMaximum: .milliseconds(20),
        restartAgent: { _ in true }
    )
    do {
        try await supervisor.start(connectTimeout: .seconds(10))
        Issue.record("the supervisor connected to an agent that broke the protocol")
    } catch {
        #expect(error == .requiredAgentUnavailable)
    }
    #expect(transport.agents.count == GuestAgentSupervisor.violationLimit)
}

/// The input route across a lost control session (#101; guest-protocol.md §5.4, input.md §7.1). The input connection of
/// a session belongs to that session, so it is released with it. The events that the route sends after the loss fail on
/// the released connection and are counted as `input.dropped.channel`. A connection that presents the new session's token
/// carries the route again.
@Test(.timeLimit(.minutes(1)))
func aLostControlSessionReleasesItsInputConnectionAndTheRouteRebinds() async throws {
    let losses = LossLog()
    let transport = InMemoryTransport { endpoint, agent, _ in
        agent.sendHello()
        agent.answer = { request in
            isGetSnapshot(request) ? .getSnapshot(snapshot(displays: [0])) : pongResult(for: request)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        backoffMinimum: .milliseconds(10),
        backoffMaximum: .milliseconds(20),
        restartAgent: { loss in
            losses.record(loss)
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    let firstToken = try #require(await supervisor.session?.sessionToken)
    // The input connection of the first session, bound to a route as the window's route is bound (DevInputBinding).
    let input = GuestConnection(endpoint: .guestInput, transport: transport, presentedToken: firstToken)
    _ = try await input.open()
    #expect(await supervisor.attachSecondary(input, presenting: firstToken))
    let session = SessionID.app(UUID())
    let route = InputRouter(channel: GuestInputChannel(connection: input))
    await route.register(session: session, displayID: 0, state: .running)
    await route.route([.cancelAll(InputTimestamp(hostNanos: 1))], from: session)
    #expect(await route.counters.batchesSent == 1)

    transport.agents[0].hangUp()
    try await eventually { await supervisor.state == .ready && transport.agents.count >= 3 }
    #expect(losses.all == [.disconnected])

    // The first session has ended, so its input connection is released, and the events that the route sends now are
    // counted as dropped on the channel.
    #expect(await input.isUsable == false)
    await route.route([.cancelAll(InputTimestamp(hostNanos: 2))], from: session)
    #expect(await route.counters.droppedChannel == 1)
    #expect(await route.counters.batchesSent == 1)

    // The new session has its own token, and a connection that presents it carries the route again.
    let secondToken = try #require(await supervisor.session?.sessionToken)
    #expect(secondToken != firstToken)
    let rebound = GuestConnection(endpoint: .guestInput, transport: transport, presentedToken: secondToken)
    _ = try await rebound.open()
    #expect(await supervisor.attachSecondary(rebound, presenting: secondToken))
    let reboundRoute = InputRouter(channel: GuestInputChannel(connection: rebound))
    await reboundRoute.register(session: session, displayID: 0, state: .running)
    await reboundRoute.route([.cancelAll(InputTimestamp(hostNanos: 3))], from: session)
    #expect(await reboundRoute.counters.batchesSent == 1)
    try await eventually {
        transport.agents[3].envelopes.contains { envelope in
            if case .inputBatch? = envelope.body { return true }
            return false
        }
    }
    await supervisor.stop()
}

/// Keeps the entries that the supervisor writes (#101).
private final class SupervisorLogRecorder: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [LogEntry] = []

    var entries: [LogEntry] {
        lock.withLock { stored }
    }

    func write(_ entry: LogEntry) {
        lock.withLock { stored.append(entry) }
    }
}

/// The release of the secondary connections at a loss is logged once, with the operation of the recovery and the
/// catalog code of the `runtime` domain. A secondary connection that presents another token is refused (#101).
@Test(.timeLimit(.minutes(1)))
func theReleaseOfTheSecondaryConnectionsIsLoggedWithItsOperation() async throws {
    let recorder = SupervisorLogRecorder()
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { request in
            isGetSnapshot(request) ? .getSnapshot(snapshot(displays: [0])) : pongResult(for: request)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        backoffMinimum: .milliseconds(10),
        backoffMaximum: .milliseconds(20),
        logSink: recorder,
        restartAgent: { _ in true }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    let token = try #require(await supervisor.session?.sessionToken)
    let input = GuestConnection(endpoint: .guestInput, transport: transport, presentedToken: token)
    _ = try await input.open()
    #expect(await supervisor.attachSecondary(input, presenting: token))
    let other = Data(repeating: 9, count: 16)
    let stranger = GuestConnection(endpoint: .guestInput, transport: transport, presentedToken: other)
    _ = try await stranger.open()
    #expect(await supervisor.attachSecondary(stranger, presenting: other) == false)
    await stranger.close()

    transport.agents[0].hangUp()
    // The agents are the control, the input, the refused stranger, and the control of the new session.
    try await eventually { await supervisor.state == .ready && transport.agents.count >= 4 }
    let released = recorder.entries.filter { $0.publicMessage.contains("secondary connection") }
    #expect(released.count == 1)
    let entry = try #require(released.first)
    #expect(entry.errorCode == "runtime.guestAgentOperationFailed")
    #expect(entry.operationID != nil)
    await supervisor.stop()
}

// MARK: - The restart budget, the snapshot state, and the bundle

@Test func theFourthDeathWithinAMinuteIsNotRestarted() {
    var budget = GuestAgentRestartBudget()
    let start = ContinuousClock.now
    let first = budget.recordDeath(at: start)
    let second = budget.recordDeath(at: start + .seconds(10))
    let third = budget.recordDeath(at: start + .seconds(20))
    let fourth = budget.recordDeath(at: start + .seconds(30))
    #expect([first, second, third, fourth] == [true, true, true, false])
}

@Test func theBudgetRefillsAfterAMinute() {
    var budget = GuestAgentRestartBudget()
    let start = ContinuousClock.now
    _ = budget.recordDeath(at: start)
    _ = budget.recordDeath(at: start + .seconds(1))
    _ = budget.recordDeath(at: start + .seconds(2))
    let later = budget.recordDeath(at: start + .seconds(61))
    #expect(later)
}

@Test func applyingAnEventTwiceLeavesTheSameState() {
    var state = GuestSnapshotState()
    var event = GPEvent()
    event.seq = 1
    event.kind = .displayAdded(display(2))
    state.apply(event)
    let once = state
    state.apply(event)
    #expect(state == once)
    #expect(state.displays.keys.sorted() == [2])

    var removed = GPEvent()
    removed.seq = 2
    var gone = GPDisplayRemoved()
    gone.displayID = 2
    removed.kind = .displayRemoved(gone)
    state.apply(removed)
    #expect(state.displays.isEmpty)
}

@Test func theBundleLoadsItsRecordAndRefusesAnotherPackage() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-072-bundle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("apk".utf8).write(to: directory.appendingPathComponent("apkrun-guest.apk"))
    let record = directory.appendingPathComponent("apkrun-guest.json")

    try Data(#"{"packageName":"io.apkrun.guest","versionCode":1000,"versionName":"0.1.0+abc"}"#.utf8).write(to: record)
    let bundle = try GuestAgentBundle.load(directory: directory)
    #expect(bundle.versionCode == 1000)
    #expect(bundle.packageName == "io.apkrun.guest")

    try Data(#"{"packageName":"io.other","versionCode":1,"versionName":"x"}"#.utf8).write(to: record)
    do {
        _ = try GuestAgentBundle.load(directory: directory)
        Issue.record("a bundle for another package was loaded")
    } catch {
        #expect(error == .bundleMissing)
    }
}

@Test func aBundleWithoutItsRecordIsMissing() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-072-empty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        _ = try GuestAgentBundle.load(directory: directory)
        Issue.record("a bundle without its record was loaded")
    } catch {
        #expect(error == .bundleMissing)
    }
}
