import CoreGraphics
import Foundation
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
