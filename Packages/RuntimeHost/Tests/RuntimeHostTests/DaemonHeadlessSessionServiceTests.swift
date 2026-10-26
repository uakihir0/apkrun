import CoreGraphics
import Foundation
import GraphicsCore
import GuestProtocol
import RuntimeAPI
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessSessionUsesSecondaryDisplayDiscardsFramesAndReleasesLease() async throws {
    let fixture = makeHeadlessServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    let launched = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))

    #expect(launched.state == .running)
    #expect(
        await fixture.service.listSessions()
            == [RuntimeSessionSnapshot(packageID: package, phase: .running)]
    )
    #expect(await fixture.agent.launchCalls == [HeadlessLaunchCall(packageID: package.rawValue, displayID: 1)])
    #expect(await fixture.registry.session(.app(launched.sessionID))?.state == .running)
    let lease = await fixture.registry.displayLease(.app(launched.sessionID))
    #expect(lease?.scanout.rawValue == 1)
    #expect(lease?.androidDisplayID == 1)

    fixture.scanouts.sendFrame(scanout: 1, sequence: 27)
    for _ in 0..<100 {
        if fixture.scanouts.acknowledgedFrames == [27] {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(fixture.scanouts.acknowledgedFrames == [27])

    let repeated = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
    #expect(repeated.sessionID == launched.sessionID)
    #expect(repeated.state == .running)
    #expect(await fixture.agent.launchCalls.count == 1)
    #expect((await fixture.displayPool.snapshot())[0].state == .allocated(.app(launched.sessionID)))

    let terminated = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))

    #expect(terminated.hadSession)
    #expect(await fixture.agent.forceStoppedPackages == [package.rawValue])
    #expect(await fixture.registry.session(.app(launched.sessionID))?.state == .ended(.userClosed))
    #expect(await fixture.service.listSessions().isEmpty)
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessSessionServiceNotifiesWhenItsPublishedSnapshotChanges() async throws {
    let changes = SessionSnapshotChangeRecorder()
    let fixture = makeHeadlessServiceFixture(onSessionSnapshotChanged: { changes.record() })
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    _ = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
    #expect(changes.count == 3)

    _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
    #expect(changes.count == 4)
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessSessionServiceNotifiesWhenFailedCloseRestoresTheSnapshot() async throws {
    let changes = SessionSnapshotChangeRecorder()
    let fixture = makeHeadlessServiceFixture(
        stopResults: [false],
        onSessionSnapshotChanged: { changes.record() }
    )
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    _ = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
    #expect(changes.count == 3)

    do {
        _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
        Issue.record("A close with remaining guest tasks should fail.")
    } catch let error as RuntimeWireError {
        #expect(error.code == "runtime.guestAgentOperationFailed")
    }

    #expect(changes.count == 5)
    #expect(await fixture.service.listSessions() == [RuntimeSessionSnapshot(packageID: package, phase: .running)])
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessSessionServiceNotifiesWhenGuestTaskEndsASession() async throws {
    let changes = SessionSnapshotChangeRecorder()
    let fixture = makeHeadlessServiceFixture(onSessionSnapshotChanged: { changes.record() })
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    _ = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
    #expect(changes.count == 3)
    await fixture.agent.sendTaskEvent(.vanished(packageID: package.rawValue, taskID: 41))
    for _ in 0..<100 {
        if changes.count == 4 {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(changes.count == 4)
    #expect(await fixture.service.listSessions().isEmpty)
}

@Test
func daemonSessionListProjectsRegistryLifecycleWithoutDisplayDetails() async throws {
    let fixture = makeHeadlessServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let session = try await fixture.registry.request(packageID: package.rawValue)

    #expect(await fixture.service.listSessions() == [RuntimeSessionSnapshot(packageID: package, phase: .starting)])

    _ = try await fixture.registry.transition(session.id, to: .waitingForRuntime)
    #expect(await fixture.service.listSessions() == [RuntimeSessionSnapshot(packageID: package, phase: .booting)])

    _ = try await fixture.registry.transition(session.id, to: .acquiringDisplay)
    #expect(
        await fixture.service.listSessions()
            == [RuntimeSessionSnapshot(packageID: package, phase: .waitingForPackage)]
    )

    _ = try await fixture.registry.transition(session.id, to: .launching)
    #expect(await fixture.service.listSessions() == [RuntimeSessionSnapshot(packageID: package, phase: .launching)])

    _ = try await fixture.registry.transition(session.id, to: .closing)
    #expect(await fixture.service.listSessions().isEmpty)
}

@Test
func daemonTerminateWithoutSessionForceStopsWithoutAllocatingADisplay() async throws {
    let fixture = makeHeadlessServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    let result = try await DaemonHeadlessSessionService.terminateWithoutSession(
        RuntimeTerminateRequest(packageID: package),
        using: fixture.agent
    )

    #expect(result.packageID == package)
    #expect(!result.hadSession)
    #expect(await fixture.agent.forceStoppedPackages == [package.rawValue])
    #expect(fixture.scanouts.configuredScanouts.isEmpty)
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

@Test
func daemonTerminateWithoutSessionRejectsAnUninstalledPackage() async throws {
    let fixture = makeHeadlessServiceFixture(isInstalled: false)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await DaemonHeadlessSessionService.terminateWithoutSession(
            RuntimeTerminateRequest(packageID: package),
            using: fixture.agent
        )
        Issue.record("Terminate must reject a package that Android does not have installed.")
    } catch {
        #expect(error.code == "runtime.packageNotInstalled")
    }

    #expect(await fixture.agent.forceStoppedPackages.isEmpty)
    #expect(fixture.scanouts.configuredScanouts.isEmpty)
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessSessionDoesNotBlockAnImmediateGuestSnapshot() async throws {
    let fixture = makeHeadlessServiceFixture(
        snapshotOnRegistration: guestSnapshot(displays: [0])
    )
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    let launched = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))

    #expect(launched.state == .running)
    #expect(await fixture.agent.launchCalls.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessSessionRejectsMissingPackageBeforeAllocatingDisplay() async throws {
    let fixture = makeHeadlessServiceFixture(isInstalled: false)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
        Issue.record("An uninstalled package must not acquire a headless display.")
    } catch {
        #expect(error.code == "runtime.packageNotInstalled")
    }

    #expect(fixture.scanouts.configuredScanouts.isEmpty)
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
    #expect(await fixture.registry.session(packageID: package.rawValue) == nil)
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessTerminationKeepsLeaseUntilGuestConfirmsTasksStopped() async throws {
    let fixture = makeHeadlessServiceFixture(stopResults: [false, true])
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let launched = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))

    do {
        _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
        Issue.record("Termination must wait for the Guest Agent to remove the package tasks.")
    } catch {
        #expect(error.code == "runtime.guestAgentOperationFailed")
    }
    #expect(await fixture.registry.session(.app(launched.sessionID))?.state == .running)
    #expect((await fixture.displayPool.snapshot())[0].state == .allocated(.app(launched.sessionID)))

    let terminated = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))

    #expect(terminated.hadSession)
    #expect(await fixture.registry.session(.app(launched.sessionID))?.state == .ended(.userClosed))
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessSessionReleasesItsLeaseWhenTheGuestTaskVanishes() async throws {
    let fixture = makeHeadlessServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let launched = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))

    await fixture.agent.sendTaskEvent(.vanished(packageID: package.rawValue, taskID: 41))
    for _ in 0..<100 {
        if await fixture.registry.session(.app(launched.sessionID))?.state == .ended(.appExited),
            (await fixture.displayPool.snapshot())[0].state == .free
        {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(await fixture.registry.session(.app(launched.sessionID))?.state == .ended(.appExited))
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessSessionReconcilesItsTaskAndReleasesLeaseAfterReconnect() async throws {
    let fixture = makeHeadlessServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let launched = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))

    await fixture.agent.resynchronize(with: guestSnapshot(displays: [1]))
    for _ in 0..<100 {
        if await fixture.registry.session(.app(launched.sessionID))?.state == .ended(.appExited),
            (await fixture.displayPool.snapshot())[0].state == .free
        {
            break
        }
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(await fixture.registry.session(.app(launched.sessionID))?.state == .ended(.appExited))
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

@Test(.timeLimit(.minutes(1)))
func daemonHeadlessShutdownClosesTheServiceBeforeFurtherLaunches() async throws {
    let fixture = makeHeadlessServiceFixture()
    await fixture.service.shutdown()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
        Issue.record("A stopped headless session service accepted a new launch.")
    } catch {
        #expect(error.code == "runtime.hostShuttingDown")
    }

    #expect(await fixture.agent.launchCalls.isEmpty)
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

private struct HeadlessServiceFixture {
    let service: DaemonHeadlessSessionService
    let registry: SessionRegistry
    let displayPool: DisplayPool
    let agent: FakeDaemonHeadlessGuestAgent
    let scanouts: FakeHeadlessScanoutController
}

private func makeHeadlessServiceFixture(
    isInstalled: Bool = true,
    stopResults: [Bool] = [true],
    snapshotOnRegistration: GuestSnapshotState? = nil,
    onSessionSnapshotChanged: @escaping @Sendable () -> Void = {}
) -> HeadlessServiceFixture {
    let displayControl = FakeHeadlessDisplayControlChannel()
    let scanouts = FakeHeadlessScanoutController(guest: displayControl)
    let displayPool = DisplayPool(
        scanouts: scanouts,
        guest: displayControl,
        limits: DisplayPoolLimits(
            attachTimeout: .milliseconds(200),
            clearTimeout: .milliseconds(200),
            removalTimeout: .milliseconds(200)
        )
    )
    let registry = SessionRegistry()
    let agent = FakeDaemonHeadlessGuestAgent(
        isInstalled: isInstalled,
        stopResults: stopResults,
        snapshotOnRegistration: snapshotOnRegistration
    )
    let service = DaemonHeadlessSessionService(
        guestAgent: agent,
        displayPool: displayPool,
        registry: registry,
        displayConfiguration: DisplayConfiguration(
            geometry: DisplayGeometry(
                pointSize: CGSize(width: 480, height: 850),
                backingScale: 1
            )
        ),
        onSessionSnapshotChanged: onSessionSnapshotChanged
    )
    return HeadlessServiceFixture(
        service: service,
        registry: registry,
        displayPool: displayPool,
        agent: agent,
        scanouts: scanouts
    )
}

private final class SessionSnapshotChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.withLock { recordedCount }
    }

    func record() {
        lock.withLock {
            recordedCount += 1
        }
    }
}

private struct HeadlessLaunchCall: Sendable, Equatable {
    let packageID: String
    let displayID: Int32
}

private actor FakeDaemonHeadlessGuestAgent: DaemonHeadlessGuestAgent {
    private let installed: Bool
    private var stopResults: [Bool]
    private let snapshotOnRegistration: GuestSnapshotState?
    private(set) var launchCalls: [HeadlessLaunchCall] = []
    private(set) var stoppedPackages: [String] = []
    private(set) var forceStoppedPackages: [String] = []
    private let taskEventContinuation: AsyncStream<DevelopmentGuestTaskEvent>.Continuation
    private var resynchronizationHandlerID: UUID?
    private var resynchronizationHandler: (@Sendable (GuestSnapshotState) async -> Void)?
    private let taskEvents: AsyncStream<DevelopmentGuestTaskEvent>

    init(isInstalled: Bool, stopResults: [Bool], snapshotOnRegistration: GuestSnapshotState?) {
        installed = isInstalled
        self.stopResults = stopResults
        self.snapshotOnRegistration = snapshotOnRegistration
        let (taskEvents, taskEventContinuation) = AsyncStream.makeStream(
            of: DevelopmentGuestTaskEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        self.taskEvents = taskEvents
        self.taskEventContinuation = taskEventContinuation
    }

    func taskEventStream() async -> AsyncStream<DevelopmentGuestTaskEvent> {
        taskEvents
    }

    func isInstalled(_ package: String) async throws(GuestAgentFailure) -> Bool {
        installed
    }

    func launch(package: String, displayID: Int32) async throws(GuestAgentFailure) -> GuestLaunchReport {
        launchCalls.append(HeadlessLaunchCall(packageID: package, displayID: displayID))
        return GuestLaunchReport(
            taskID: 41,
            component: "\(package)/.MainActivity",
            outcome: "started"
        )
    }

    func stopApplication(package: String) async throws(GuestAgentFailure) -> Bool {
        stoppedPackages.append(package)
        return stopResults.isEmpty ? true : stopResults.removeFirst()
    }

    func forceStopApplication(package: String) async throws(GuestAgentFailure) -> Bool {
        forceStoppedPackages.append(package)
        return stopResults.isEmpty ? true : stopResults.removeFirst()
    }

    func addResynchronizationHandler(
        _ handler: @escaping @Sendable (GuestSnapshotState) async -> Void
    ) async -> UUID {
        let id = UUID()
        resynchronizationHandlerID = id
        resynchronizationHandler = handler
        if let snapshotOnRegistration {
            await handler(snapshotOnRegistration)
        }
        return id
    }

    func removeResynchronizationHandler(_ id: UUID) async {
        guard resynchronizationHandlerID == id else {
            return
        }
        resynchronizationHandlerID = nil
        resynchronizationHandler = nil
    }

    func sendTaskEvent(_ event: DevelopmentGuestTaskEvent) {
        taskEventContinuation.yield(event)
    }

    func resynchronize(with snapshot: GuestSnapshotState) async {
        await resynchronizationHandler?(snapshot)
    }
}

private func guestSnapshot(
    displays displayIDs: [Int32],
    tasks taskRecords: [(taskID: Int32, displayID: Int32, packageID: String)] = []
) -> GuestSnapshotState {
    var snapshot = GPSnapshot()
    snapshot.displays = displayIDs.map { displayID in
        var display = GPDisplayInfo()
        display.displayID = displayID
        return display
    }
    snapshot.tasks = taskRecords.map { record in
        var task = GPTaskInfo()
        task.taskID = record.taskID
        task.displayID = record.displayID
        task.package = record.packageID
        return task
    }
    var state = GuestSnapshotState()
    state.replace(with: snapshot)
    return state
}

private final class FakeHeadlessDisplayControlChannel: DisplayControlChannel, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<GuestDisplayEvent>.Continuation
    private var displays: [Int32: GuestDisplaySnapshot] = [
        0: GuestDisplaySnapshot(
            displayID: 0,
            mode: GuestDisplaySize(width: 1080, height: 2400),
            densityDPI: 420
        )
    ]

    let displayEvents: AsyncStream<GuestDisplayEvent>

    init() {
        let (events, continuation) = AsyncStream.makeStream(of: GuestDisplayEvent.self)
        displayEvents = events
        self.continuation = continuation
    }

    func displaySnapshot() async -> [GuestDisplaySnapshot] {
        lock.withLock { Array(displays.values) }
    }

    func setDisplayPolicy(
        _ displayID: Int32,
        densityDPI: Int,
        imePolicy: GuestDisplayIMEPolicy
    ) async throws(DisplayControlFailure) {}

    func clearDisplay(_ displayID: Int32) async throws(DisplayControlFailure) {
        emit(.tasksCleared(displayID: displayID))
    }

    func emit(_ event: GuestDisplayEvent) {
        lock.withLock {
            switch event {
            case .added(let display), .changed(let display):
                displays[display.displayID] = display
            case .removed(let displayID):
                displays[displayID] = nil
            case .tasksCleared:
                break
            }
            continuation.yield(event)
        }
    }
}

private final class FakeHeadlessScanoutController: ScanoutController, @unchecked Sendable {
    private let lock = NSLock()
    private let guest: FakeHeadlessDisplayControlChannel
    private var displaysByScanout: [Int: Int32] = [:]
    private var continuations: [Int: AsyncStream<ScanoutFrame>.Continuation] = [:]
    private var generation: UInt64 = 0
    private var acknowledged: [UInt64] = []
    private var configured: [Int] = []

    init(guest: FakeHeadlessDisplayControlChannel) {
        self.guest = guest
    }

    var configuredScanouts: [Int] {
        lock.withLock { configured }
    }

    var acknowledgedFrames: [UInt64] {
        lock.withLock { acknowledged }
    }

    func configure(_ scanout: ScanoutID, mode: DisplayMode) throws(GraphicsFailure) {
        let result = lock.withLock { () -> (displayID: Int32, isChanged: Bool) in
            configured.append(scanout.rawValue)
            if let displayID = displaysByScanout[scanout.rawValue] {
                return (displayID, true)
            }
            let displayID = Int32(scanout.rawValue)
            displaysByScanout[scanout.rawValue] = displayID
            return (displayID, false)
        }
        let display = GuestDisplaySnapshot(
            displayID: result.displayID,
            uniqueID: "headless-scanout-\(scanout.rawValue)",
            mode: GuestDisplaySize(width: mode.widthPixels, height: mode.heightPixels),
            densityDPI: mode.dotsPerInch,
            product: GuestDisplayProductInfo(manufacturerPnpID: "APK", productID: Int32(scanout.rawValue))
        )
        guest.emit(result.isChanged ? .changed(display) : .added(display))
    }

    func disable(_ scanout: ScanoutID) {
        let result = lock.withLock { () -> (Int32?, AsyncStream<ScanoutFrame>.Continuation?) in
            let displayID = displaysByScanout.removeValue(forKey: scanout.rawValue)
            let continuation = continuations.removeValue(forKey: scanout.rawValue)
            return (displayID, continuation)
        }
        result.1?.finish()
        if let displayID = result.0 {
            guest.emit(.removed(displayID: displayID))
        }
    }

    func attach(_ scanout: ScanoutID, width: Int, height: Int) throws(GraphicsFailure) -> ScanoutPoolHandle {
        makePool(scanout)
    }

    func reconfigure(
        _ scanout: ScanoutID,
        mode: DisplayMode,
        width: Int,
        height: Int
    ) throws(GraphicsFailure) -> ScanoutPoolHandle {
        makePool(scanout)
    }

    func detachPool(_ scanout: ScanoutID, generation: UInt64?) {}

    func sendFrame(scanout: Int, sequence: UInt64) {
        let continuation = lock.withLock { continuations[scanout] }
        continuation?.yield(.frameReady(generation: 1, bufferIndex: 0, sequence: sequence))
    }

    private func makePool(_ scanout: ScanoutID) -> ScanoutPoolHandle {
        let (frames, continuation) = AsyncStream<ScanoutFrame>.makeStream()
        let poolGeneration = lock.withLock { () -> UInt64 in
            generation &+= 1
            continuations[scanout.rawValue] = continuation
            return generation
        }
        return ScanoutPoolHandle(
            generation: poolGeneration,
            surfaces: [],
            frames: frames,
            acknowledgeFrame: { [weak self] sequence in
                self?.lock.withLock {
                    self?.acknowledged.append(sequence)
                }
            }
        )
    }
}
