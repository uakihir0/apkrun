import CoreGraphics
import Foundation
import GraphicsCore
import GuestProtocol
import Testing

@testable import RuntimeCore

@Test
func leasedSessionUsesSecondaryDisplayAndReleasesLeaseOnRuntimeStop() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let displayPool = DisplayPool(scanouts: scanouts, guest: guest)
    let registry = SessionRegistry()
    let configuration = DisplayConfiguration(
        geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
    )

    let session = try await registry.requestLeased(
        packageID: "io.apkrun.fixture.hellotext",
        configuration: configuration,
        displayPool: displayPool
    )
    #expect(session.displayID == 1)
    #expect(session.state == .acquiringDisplay)
    #expect((await displayPool.snapshot())[0].state == .allocated(session.id))

    let repeated = try await registry.requestLeased(
        packageID: "io.apkrun.fixture.hellotext",
        configuration: configuration,
        displayPool: displayPool
    )
    #expect(repeated.id == session.id)
    #expect(scanouts.configuredScanouts == [1])
    await #expect(throws: SessionRegistryFailure.sessionAlreadyExists(packageID: session.packageID)) {
        try await registry.request(packageID: session.packageID)
    }
    let primarySession = try await registry.request(packageID: "io.apkrun.fixture.hellocompose")
    #expect(primarySession.displayID == 0)

    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: session.packageID, taskID: 41)
    _ = try await registry.transition(session.id, to: .running)
    let ended = try await registry.transition(session.id, to: .ended(.runtimeStopped))

    #expect(ended.displayID == 1)
    #expect(ended.state == .ended(.runtimeStopped))
    #expect((await displayPool.snapshot())[0].state == .free)
    #expect(scanouts.disabledScanouts == [1])

    _ = try await registry.transition(primarySession.id, to: .ended(.runtimeStopped))
    let legacySession = try await registry.request(packageID: session.packageID)
    #expect(legacySession.displayID == 0)
}

@Test
func leasedSessionReleasesOnLastTaskExit() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let displayPool = DisplayPool(scanouts: scanouts, guest: guest)
    let registry = SessionRegistry()
    let session = try await registry.requestLeased(
        packageID: "io.apkrun.fixture.hellocompose",
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
        ),
        displayPool: displayPool
    )

    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: session.packageID, taskID: 42)
    _ = try await registry.transition(session.id, to: .running)
    let ended = await registry.taskVanished(packageID: session.packageID, taskID: 42)

    #expect(ended?.state == .ended(.appExited))
    #expect((await displayPool.snapshot())[0].state == .free)
    #expect(scanouts.disabledScanouts == [1])
}

@Test
func primaryCompatibilityLeaseReservesDisplayZeroBeforeTheGuestOperationCompletes() async throws {
    let guest = FakeDisplayControlChannel()
    guest.emit(
        .changed(
            GuestDisplaySnapshot(
                displayID: 0,
                mode: GuestDisplaySize(width: 480, height: 850),
                densityDPI: 420
            )
        )
    )
    let scanouts = FakeScanoutController(guest: guest)
    let (frames, _) = AsyncStream<ScanoutFrame>.makeStream()
    let displayPool = DisplayPool(
        scanouts: scanouts,
        guest: guest,
        primaryPool: ScanoutPoolHandle(generation: 1, surfaces: [], frames: frames)
    )
    let registry = SessionRegistry()
    let configuration = DisplayConfiguration(
        geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1),
        mode: .primaryDisplayCompatibility
    )
    let session = try await registry.requestLeased(
        packageID: "io.apkrun.fixture.hellotext",
        configuration: configuration,
        displayPool: displayPool
    )

    #expect(session.displayID == 0)
    #expect(await registry.displayLease(session.id)?.scanout.rawValue == 0)
    await #expect(throws: SessionRegistryFailure.displayInUse(packageID: session.packageID)) {
        try await registry.request(packageID: "io.apkrun.fixture.hellocompose")
    }
    await #expect(throws: SessionRegistryFailure.displayInUse(packageID: session.packageID)) {
        try await registry.requestLeased(
            packageID: "io.apkrun.fixture.hellocompose",
            configuration: configuration,
            displayPool: displayPool
        )
    }

    _ = try await registry.transition(session.id, to: .ended(.runtimeStopped))
    #expect(await registry.displayLease(session.id) == nil)
    #expect(
        guest.policySnapshot()
            == [
                DisplayPolicyCall(displayID: 0, densityDPI: 160, imePolicy: .local),
                DisplayPolicyCall(displayID: 0, densityDPI: 420, imePolicy: .local),
            ]
    )
    #expect(scanouts.configuredScanouts.isEmpty)
    #expect(scanouts.disabledScanouts.isEmpty)
}

@Test
func snapshotReconciliationReplacesRunningTasksAndEndsExitedBackgroundSession() async throws {
    let registry = SessionRegistry()
    let session = try await registry.request(packageID: "io.apkrun.fixture.hellotext")
    _ = try await registry.transition(session.id, to: .waitingForRuntime)
    _ = try await registry.transition(session.id, to: .acquiringDisplay)
    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: session.packageID, taskID: 41)
    _ = try await registry.transition(session.id, to: .running)

    let withPackageTask = reconciliationGuestState(
        displays: [0],
        tasks: [
            (taskID: 84, displayID: 0, packageID: session.packageID),
            (taskID: 85, displayID: 0, packageID: "io.apkrun.fixture.hellocompose"),
        ]
    )
    let running = try await registry.reconcile(sessionID: session.id, against: withPackageTask)
    #expect(running.action == .none)
    #expect(running.session.state == .running)
    #expect(running.session.taskIDs == [84])

    _ = try await registry.transition(session.id, to: .backgrounded)
    let withoutPackageTask = reconciliationGuestState(
        displays: [0],
        tasks: [(taskID: 85, displayID: 0, packageID: "io.apkrun.fixture.hellocompose")]
    )
    let exited = try await registry.reconcile(sessionID: session.id, against: withoutPackageTask)
    #expect(exited.action == .none)
    #expect(exited.session.state == .ended(.appExited))
    #expect(exited.session.taskIDs.isEmpty)
}

@Test
func snapshotReconciliationReleasesLostDisplayBeforeReturning() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let displayPool = DisplayPool(scanouts: scanouts, guest: guest)
    let registry = SessionRegistry()
    let session = try await registry.requestLeased(
        packageID: "io.apkrun.fixture.hellotext",
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
        ),
        displayPool: displayPool
    )
    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: session.packageID, taskID: 41)
    _ = try await registry.transition(session.id, to: .running)

    let result = try await registry.reconcile(
        sessionID: session.id,
        against: reconciliationGuestState(displays: [0])
    )
    await registry.waitForPendingDisplayReleases()

    #expect(result.session.state == .ended(.error(.displayLost)))
    #expect((await displayPool.snapshot())[0].state == .free)
    #expect(scanouts.disabledScanouts == [1])
}

@Test
func snapshotReconciliationKeepsLaunchingSessionAndRequestsIdempotentRelaunch() async throws {
    let registry = SessionRegistry()
    let session = try await registry.request(packageID: "io.apkrun.fixture.hellotext")
    _ = try await registry.transition(session.id, to: .waitingForRuntime)
    _ = try await registry.transition(session.id, to: .acquiringDisplay)
    _ = try await registry.transition(session.id, to: .launching)

    let noTasks = reconciliationGuestState(displays: [0])
    let relaunch = try await registry.reconcile(sessionID: session.id, against: noTasks)
    #expect(relaunch.action == .relaunchApplication)
    #expect(relaunch.session.state == .launching)

    var task = GPTaskInfo()
    task.taskID = 90
    task.displayID = 0
    task.package = session.packageID
    var guestSnapshot = GPSnapshot()
    guestSnapshot.displays = [reconciliationDisplay(0)]
    guestSnapshot.tasks = [task]
    var withTask = GuestSnapshotState()
    withTask.replace(with: guestSnapshot)

    let resumed = try await registry.reconcile(sessionID: session.id, against: withTask)
    #expect(resumed.action == .none)
    #expect(resumed.session.state == .launching)
    #expect(resumed.session.taskIDs == [90])

    let lateLaunchReply = await registry.launchCompleted(packageID: session.packageID, taskID: 90)
    #expect(lateLaunchReply?.state == .launching)
    #expect(lateLaunchReply?.taskIDs == [90])

    let exitedBeforeFirstFrame = await registry.taskVanished(packageID: session.packageID, taskID: 90)
    #expect(exitedBeforeFirstFrame?.state == .ended(.appExited))
}

@Test
func snapshotReconciliationEndsAndReleasesSessionWhenItsDisplayIsMissing() async throws {
    let guest = FakeDisplayControlChannel()
    let scanouts = FakeScanoutController(guest: guest)
    let displayPool = DisplayPool(scanouts: scanouts, guest: guest)
    let registry = SessionRegistry()
    let session = try await registry.requestLeased(
        packageID: "io.apkrun.fixture.hellotext",
        configuration: DisplayConfiguration(
            geometry: DisplayGeometry(pointSize: CGSize(width: 480, height: 850), backingScale: 1)
        ),
        displayPool: displayPool
    )
    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: session.packageID, taskID: 41)
    _ = try await registry.transition(session.id, to: .running)

    let lost = try await registry.reconcile(
        sessionID: session.id,
        against: reconciliationGuestState(displays: [0])
    )
    #expect(lost.action == .none)
    #expect(lost.session.state == .ended(.error(.displayLost)))
    #expect(lost.session.taskIDs == [41])
    #expect(await registry.displayLease(session.id) == nil)

    for _ in 0..<20 {
        if (await displayPool.snapshot()).first?.state == .free {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect((await displayPool.snapshot())[0].state == .free)
    #expect(scanouts.disabledScanouts == [1])
}

@Test
func snapshotReconciliationIgnoresPlaceholderDisplayBeforeAcquisition() async throws {
    let registry = SessionRegistry()
    let session = try await registry.request(packageID: "io.apkrun.fixture.hellotext")

    let result = try await registry.reconcile(
        sessionID: session.id,
        against: reconciliationGuestState(displays: [])
    )

    #expect(result.action == .none)
    #expect(result.session.displayID == 0)
    #expect(result.session.state == .requested)
}

private func reconciliationGuestState(
    displays displayIDs: [Int32],
    tasks: [(taskID: Int32, displayID: Int32, packageID: String)] = []
) -> GuestSnapshotState {
    var snapshot = GPSnapshot()
    snapshot.displays = displayIDs.map(reconciliationDisplay)
    snapshot.tasks = tasks.map { taskRecord in
        var task = GPTaskInfo()
        task.taskID = taskRecord.taskID
        task.displayID = taskRecord.displayID
        task.package = taskRecord.packageID
        return task
    }
    var state = GuestSnapshotState()
    state.replace(with: snapshot)
    return state
}

private func reconciliationDisplay(_ id: Int32) -> GPDisplayInfo {
    var display = GPDisplayInfo()
    display.displayID = id
    return display
}
