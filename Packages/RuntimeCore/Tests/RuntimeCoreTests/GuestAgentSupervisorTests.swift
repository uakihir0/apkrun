import Foundation
import GuestProtocol
import InputCore
import Testing

@testable import RuntimeCore

/// The supervisor's resync, keepalive, and recovery, run against in-memory agents (guest-protocol.md §6,
/// guest-components.md §3.3; #73 T0).

private func eventually(within seconds: Double = 8, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while await !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test func failedBootStatusDoesNotReportATornDownAgentAsConnected() {
    let version = ProtocolVersion(major: 1, minor: 0)
    let retained = RuntimeSupervisor.guestAgentStatusAfterStop(
        GuestAgentSupervisor.StatusSnapshot(state: .ready, protocolVersion: version),
        preservingFailure: true
    )
    #expect(retained.state == .unavailable)
    #expect(retained.protocolVersion == version)

    let incompatibleVersion = ProtocolVersion(major: 2, minor: 0)
    let incompatible = RuntimeSupervisor.guestAgentStatusAfterStop(
        GuestAgentSupervisor.StatusSnapshot(state: .incompatible, protocolVersion: incompatibleVersion),
        preservingFailure: true
    )
    #expect(incompatible.state == .incompatible)
    #expect(incompatible.protocolVersion == incompatibleVersion)

    let stopped = RuntimeSupervisor.guestAgentStatusAfterStop(
        GuestAgentSupervisor.StatusSnapshot(state: .ready, protocolVersion: version),
        preservingFailure: false
    )
    #expect(stopped.state == .stopped)
    #expect(stopped.protocolVersion == nil)
}

private func display(_ id: Int32) -> GPDisplayInfo {
    var info = GPDisplayInfo()
    info.displayID = id
    info.uniqueID = "display-\(id)"
    return info
}

private func snapshot(displays: [Int32], uptimeMillis: UInt64? = nil) -> GPSnapshot {
    var snapshot = GPSnapshot()
    snapshot.displays = displays.map(display)
    if let uptimeMillis {
        var system = GPSystemState()
        system.androidUptimeMs = uptimeMillis
        system.bootCompleted = true
        snapshot.system = system
    }
    return snapshot
}

@Test(.timeLimit(.minutes(1)))
func snapshotResynchronisationUsesTheRemainingInitialConnectionDeadline() async throws {
    let transport = InMemoryTransport { _, agent, _ in
        agent.sendHello()
        agent.answer = { _ in nil }
    }
    let supervisor = GuestAgentSupervisor(
        transport: DelayedTransport(inner: transport, delay: .milliseconds(200)),
        restartAgent: { _ in true }
    )
    let started = ContinuousClock.now

    do {
        try await supervisor.start(connectTimeout: .milliseconds(300))
        Issue.record("the connection succeeded without a snapshot")
    } catch {
        #expect(error == .connectTimedOut)
    }
    #expect(ContinuousClock.now - started < .seconds(1))
    #expect(
        transport.agents.first?.requests.contains { request in
            if case .getSnapshot? = request.op {
                return true
            }
            return false
        } == true
    )
    await supervisor.stop()
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

/// Pauses the second restart callback so a test can stop the supervisor during the await.
private actor RestartGate {
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

/// Holds one selected snapshot reconciliation so the test can check the readiness barrier.
private actor SnapshotReconciliationGate {
    private let pausesOnInvocation: Int
    private var invocationCount = 0
    private var observedSnapshots: [GuestSnapshotState] = []
    private var entryContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(pausesOnInvocation: Int) {
        self.pausesOnInvocation = pausesOnInvocation
    }

    func reconcile(_ snapshot: GuestSnapshotState) async {
        invocationCount += 1
        observedSnapshots.append(snapshot)
        guard invocationCount == pausesOnInvocation else {
            return
        }
        entryContinuation?.resume()
        entryContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard invocationCount < pausesOnInvocation else { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    var snapshots: [GuestSnapshotState] { observedSnapshots }
}

/// Rechecks a scheduled launch after reconciliation, like the embedded session service does behind its operation gate.
private actor LaunchingSessionReconciler {
    private let registry: SessionRegistry
    private let sessionID: SessionID
    private let relaunchGate: RelaunchCheckGate
    private var recordedActions: [SessionReconciliationAction] = []
    private var relaunchChecks = 0
    private var relaunchCount = 0

    init(registry: SessionRegistry, sessionID: SessionID, relaunchGate: RelaunchCheckGate) {
        self.registry = registry
        self.sessionID = sessionID
        self.relaunchGate = relaunchGate
    }

    func reconcile(_ snapshot: GuestSnapshotState) async {
        guard let result = try? await registry.reconcile(sessionID: sessionID, against: snapshot) else {
            return
        }
        recordedActions.append(result.action)
        guard result.action == .relaunchApplication else {
            return
        }
        Task {
            await relaunchGate.wait()
            await checkWhetherRelaunchIsStillNeeded()
        }
    }

    private func checkWhetherRelaunchIsStillNeeded() async {
        relaunchChecks += 1
        guard let current = await registry.session(sessionID),
            current.state == .launching,
            current.taskIDs.isEmpty
        else {
            return
        }
        relaunchCount += 1
    }

    var actions: [SessionReconciliationAction] { recordedActions }
    var completedRelaunchChecks: Int { relaunchChecks }
    var relaunched: Int { relaunchCount }
}

/// Delays the relaunch recheck until the latest complete snapshot has been applied.
private actor RelaunchCheckGate {
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isPaused = true
        pauseContinuation?.resume()
        pauseContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilPaused() async {
        guard !isPaused else { return }
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Records Android reboot notifications from a supervisor stream.
private final class AndroidRestartLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [GuestAndroidRestart] = []

    func record(_ restart: GuestAndroidRestart) {
        lock.withLock { values.append(restart) }
    }

    var all: [GuestAndroidRestart] {
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
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    transport.agents[0].hangUp()
    try await eventually { await supervisor.state == .reconnecting }
    #expect(await supervisor.protocolVersion?.description == "1.0")
    try await eventually { await supervisor.state == .ready && transport.agents.count >= 2 }
    #expect(losses.all == [.disconnected])
    let displays = await supervisor.snapshot.displays.keys.sorted()
    #expect(displays == [3])
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func queuedSendsWaitForSnapshotReconciliationAndEventsStayOrdered() async throws {
    let gate = SnapshotReconciliationGate(pausesOnInvocation: 2)
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
        requestReconnectTimeout: .seconds(2),
        restartAgent: { _ in true }
    )
    await supervisor.addResynchronizationHandler { snapshot in
        await gate.reconcile(snapshot)
    }
    try await supervisor.start(connectTimeout: .seconds(2))

    transport.agents[0].hangUp()
    await gate.waitUntilPaused()
    #expect(await supervisor.state == .reconnecting)
    #expect(await gate.snapshots.map { $0.displays.keys.sorted() } == [[0], [3]])
    #expect(await supervisor.session?.sessionToken != nil)
    #expect(await supervisor.readySessionToken() == nil)

    let queuedSend = Task {
        try await supervisor.send(GuestPing(nonce: 123), timeout: .seconds(1))
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.agents[1].requests.filter(isPing).isEmpty)

    // Events received while the host applies the snapshot remain buffered behind the same barrier.
    transport.agents[1].sendEvent(.displayAdded(display(9)))
    try await Task.sleep(for: .milliseconds(20))
    let eventIsStillBuffered = await supervisor.snapshot.displays[9] == nil
    #expect(eventIsStillBuffered)
    await gate.release()

    let pong = try await queuedSend.value
    #expect(pong.nonce == 123)
    try await eventually {
        let state = await supervisor.state
        let hasReplayedEvent = await supervisor.snapshot.displays[9] != nil
        return state == .ready && hasReplayedEvent
    }
    #expect(await supervisor.readySessionToken() == supervisor.session?.sessionToken)
    #expect(transport.agents[1].requests.filter(isPing).count == 1)
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func taskEventDuringReconciliationPreventsRelaunchFromStaleSnapshot() async throws {
    let sessionPackage = "io.apkrun.fixture.hellotext"
    let registry = SessionRegistry()
    let session = try await registry.request(packageID: sessionPackage)
    _ = try await registry.transition(session.id, to: .waitingForRuntime)
    _ = try await registry.transition(session.id, to: .acquiringDisplay)
    _ = try await registry.transition(session.id, to: .launching)

    let taskGate = SnapshotReconciliationGate(pausesOnInvocation: 2)
    let relaunchGate = RelaunchCheckGate()
    let sessionReconciler = LaunchingSessionReconciler(
        registry: registry,
        sessionID: session.id,
        relaunchGate: relaunchGate
    )
    let transport = InMemoryTransport { _, agent, number in
        agent.sendHello()
        agent.answer = { request in
            guard isGetSnapshot(request) else { return pongResult(for: request) }
            let state =
                number == 1
                ? guestSnapshot(displays: [0], tasks: [(taskID: 90, packageID: sessionPackage)])
                : guestSnapshot(displays: [0])
            return .getSnapshot(state)
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in true }
    )
    await supervisor.addResynchronizationHandler { state in
        await sessionReconciler.reconcile(state)
        await taskGate.reconcile(state)
    }
    try await supervisor.start(connectTimeout: .seconds(2))
    #expect(await registry.session(session.id)?.taskIDs == [90])

    transport.agents[0].hangUp()
    await taskGate.waitUntilPaused()
    #expect(await sessionReconciler.actions == [.none, .relaunchApplication])
    await relaunchGate.waitUntilPaused()

    var appearedTask = GPTaskInfo()
    appearedTask.taskID = 91
    appearedTask.displayID = 0
    appearedTask.package = sessionPackage
    transport.agents[1].sendEvent(.taskAppeared(appearedTask))
    try await Task.sleep(for: .milliseconds(20))
    #expect(await supervisor.snapshot.tasks[91] == nil)

    await taskGate.release()
    try await eventually {
        let state = await supervisor.state
        let hasTask = await supervisor.snapshot.tasks[91] != nil
        let reconciliationCount = await taskGate.snapshots.count
        return state == .ready && hasTask && reconciliationCount == 3
    }
    #expect(await sessionReconciler.actions == [.none, .relaunchApplication, .none])
    #expect(await registry.session(session.id)?.state == .launching)
    #expect(await registry.session(session.id)?.taskIDs == [91])

    await relaunchGate.release()
    try await eventually { await sessionReconciler.completedRelaunchChecks == 1 }
    #expect(await sessionReconciler.relaunched == 0)
    await supervisor.stop()
}

@Test(.timeLimit(.minutes(1)))
func androidRestartIsDetectedByAnUptimeRollbackButAgentRestartIsNot() async throws {
    let transport = InMemoryTransport { _, agent, number in
        agent.sendHello()
        agent.answer = { request in
            guard isGetSnapshot(request) else { return pongResult(for: request) }
            let uptimeMillis: UInt64 =
                switch number {
                case 1: 5_000
                case 2: 6_000
                default: 1_000
                }
            return .getSnapshot(snapshot(displays: [0], uptimeMillis: uptimeMillis))
        }
    }
    let supervisor = GuestAgentSupervisor(
        transport: transport,
        keepaliveInterval: .seconds(60),
        restartAgent: { _ in true }
    )
    let restartLog = AndroidRestartLog()
    let restartEvents = supervisor.androidRestartEvents
    let monitor = Task {
        for await restart in restartEvents {
            restartLog.record(restart)
        }
    }

    try await supervisor.start(connectTimeout: .seconds(2))
    transport.agents[0].hangUp()
    try await eventually { await supervisor.state == .ready && transport.agents.count >= 2 }
    #expect(restartLog.all.isEmpty)

    transport.agents[1].hangUp()
    try await eventually { !restartLog.all.isEmpty }
    #expect(
        restartLog.all == [
            GuestAndroidRestart(previousUptimeMillis: 6_000, currentUptimeMillis: 1_000)
        ]
    )
    await supervisor.stop()
    monitor.cancel()
}

private func guestSnapshot(
    displays displayIDs: [Int32],
    tasks taskRecords: [(taskID: Int32, packageID: String)] = []
) -> GPSnapshot {
    var result = GPSnapshot()
    result.displays = displayIDs.map(display)
    result.tasks = taskRecords.map { record in
        var task = GPTaskInfo()
        task.taskID = record.taskID
        task.displayID = 0
        task.package = record.packageID
        return task
    }
    return result
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
    #expect(await supervisor.state == .unavailable)
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
    let status = await supervisor.statusSnapshot()
    #expect(status.state == .incompatible)
    #expect(status.protocolVersion?.description == "2.0")
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
func aStoppedSupervisorDoesNotBecomeUnavailableAfterADeferredRestart() async throws {
    let losses = LossLog()
    let gate = RestartGate()
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
            if losses.all.count == 2 {
                await gate.pause()
                return false
            }
            return true
        }
    )
    try await supervisor.start(connectTimeout: .seconds(2))
    transport.refuseNext(1)
    transport.agents[0].hangUp()
    await gate.waitUntilEntered()

    await supervisor.stop()
    await gate.release()
    try await Task.sleep(for: .milliseconds(30))

    #expect(await supervisor.state == .stopped)
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

// MARK: - The restart budget, the snapshot state, and the bundle

/// A secondary input connection belongs to the control session that opened it. The route drops an event on that
/// released connection, then carries input again over a connection presenting the next session's token (#101).
@Test(.timeLimit(.minutes(1)))
func aLostControlSessionReleasesItsInputConnectionAndTheRouteRebinds() async throws {
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
    let firstToken = try #require(await supervisor.session?.sessionToken)
    let input = GuestConnection(endpoint: .guestInput, transport: transport, presentedToken: firstToken)
    _ = try await input.open()
    #expect(await supervisor.attachSecondary(input, presenting: Data([9])) == false)
    #expect(await supervisor.attachSecondary(input, presenting: firstToken))
    let session = SessionID.app(UUID())
    let route = InputRouter(channel: GuestInputChannel(connection: input))
    await route.register(session: session, displayID: 0, state: .running)
    await route.focusChanged(session, focused: true, generation: 1)
    await route.route([.cancelAll(InputTimestamp(hostNanos: 1))], from: session)
    #expect(await route.counters.batchesSent == 1)

    transport.agents[0].hangUp()
    try await eventually { await supervisor.state == .ready && transport.agents.count >= 3 }
    #expect(losses.all == [.disconnected])
    #expect(await input.isUsable == false)

    await route.route([.cancelAll(InputTimestamp(hostNanos: 2))], from: session)
    #expect(await route.counters.droppedChannel == 1)
    #expect(await route.counters.batchesSent == 1)

    let nextToken = try #require(await supervisor.session?.sessionToken)
    #expect(nextToken != firstToken)
    let rebound = GuestConnection(endpoint: .guestInput, transport: transport, presentedToken: nextToken)
    _ = try await rebound.open()
    #expect(await supervisor.attachSecondary(rebound, presenting: nextToken))
    let reboundRoute = InputRouter(channel: GuestInputChannel(connection: rebound))
    await reboundRoute.register(session: session, displayID: 0, state: .running)
    await reboundRoute.focusChanged(session, focused: true, generation: 1)
    await reboundRoute.route([.cancelAll(InputTimestamp(hostNanos: 3))], from: session)
    #expect(await reboundRoute.counters.batchesSent == 1)
    try await eventually {
        transport.agents[3].envelopes.contains { envelope in
            if case .inputBatch? = envelope.body { return true }
            return false
        }
    }
    await supervisor.stop()
    #expect(await rebound.isUsable == false)
}

@Test(.timeLimit(.minutes(1)))
func aReplacementSecondaryClosesThePreviousConnectionForItsEndpoint() async throws {
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
    let token = try #require(await supervisor.readySessionToken())

    let first = GuestConnection(endpoint: .guestInput, transport: transport, presentedToken: token)
    _ = try await first.open()
    #expect(await supervisor.attachSecondary(first, presenting: token))
    let replacement = GuestConnection(endpoint: .guestInput, transport: transport, presentedToken: token)
    _ = try await replacement.open()
    #expect(await supervisor.attachSecondary(replacement, presenting: token))
    #expect(await first.isUsable == false)
    #expect(await replacement.isUsable)

    await supervisor.stop()
    #expect(await replacement.isUsable == false)
}

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
