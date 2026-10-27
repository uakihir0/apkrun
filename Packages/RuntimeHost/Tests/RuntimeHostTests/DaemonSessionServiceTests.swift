import CoreGraphics
import Foundation
import GraphicsCore
import GuestProtocol
import IOSurface
import RuntimeAPI
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func daemonSessionOpensWindowAndAcknowledgesFramesOnlyAfterDisplayCommit() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let clientToken = SessionConnectionToken()
    let connectionID = ObjectIdentifier(clientToken)
    let (frameStream, frameContinuation) = AsyncStream<FrameReady>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: connectionID,
        frameReady: { frameContinuation.yield($0) },
        closeRequested: { true }
    )

    #expect(opened.descriptor.state == .running)
    #expect(opened.surfaces.count == SurfaceSet.requiredSurfaceCount)
    #expect(opened.descriptor.surfaces.pixelSize.width > 0)
    #expect(await fixture.agent.launchCalls == [SessionLaunchCall(packageID: package.rawValue, displayID: 1)])
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.state == .running)
    let lease = await fixture.registry.displayLease(.app(opened.descriptor.sessionID))
    #expect(lease?.scanout.rawValue == 1)
    #expect(lease?.androidDisplayID == 1)
    #expect(lease?.mode.zoom == 1.25)

    var frameIterator = frameStream.makeAsyncIterator()
    fixture.scanouts.sendFrame(scanout: 1, sequence: 27)
    let frame = try #require(await frameIterator.next())
    #expect(frame.generation == opened.descriptor.surfaces.generation)
    #expect(frame.surfaceIndex == 0)
    #expect(frame.frameSeq == 27)
    #expect(fixture.scanouts.acknowledgedFrames.isEmpty)

    await fixture.service.frameDisplayed(
        FrameDisplayed(generation: frame.generation, frameSeq: frame.frameSeq),
        from: connectionID
    )
    #expect(fixture.scanouts.acknowledgedFrames == [27])

    let repeated = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
    #expect(repeated.sessionID == opened.descriptor.sessionID)
    #expect(repeated.state == .running)
    #expect(await fixture.agent.launchCalls.count == 1)
    #expect((await fixture.displayPool.snapshot())[0].state == .allocated(.app(opened.descriptor.sessionID)))

    let terminated = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))

    #expect(terminated.hadSession)
    #expect(await fixture.agent.forceStoppedPackages == [package.rawValue])
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.state == .ended(.userClosed))
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionRestartUsesItsOwnedDisplayAndKeepsTheSessionOpen() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let clientToken = SessionConnectionToken()
    let connectionID = ObjectIdentifier(clientToken)
    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: connectionID,
        frameReady: { _ in },
        closeRequested: { true }
    )
    let originalLease = await fixture.registry.displayLease(.app(opened.descriptor.sessionID))
    let request = RestartAppRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: opened.descriptor.sessionID,
        packageID: package
    )

    try await fixture.service.restartApp(
        request,
        from: connectionID,
        authorizedPackageID: package
    )

    let session = await fixture.registry.session(.app(opened.descriptor.sessionID))
    let restartedLease = await fixture.registry.displayLease(.app(opened.descriptor.sessionID))
    #expect(session?.state == .running)
    #expect(session?.displayID == opened.descriptor.displayID)
    #expect(session?.taskIDs == [41])
    #expect(restartedLease?.leaseID == originalLease?.leaseID)
    #expect(await fixture.agent.stoppedPackages == [package.rawValue])
    #expect(
        await fixture.agent.sessionCallOrder == [
            "launch:\(opened.descriptor.displayID)",
            "stop:\(package.rawValue)",
            "launch:\(opened.descriptor.displayID)",
        ])
    #expect((await fixture.displayPool.snapshot())[0].state == .allocated(.app(opened.descriptor.sessionID)))

    _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionRestartRejectsAnotherSessionPackageOrConnection() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let anotherPackage = try #require(RuntimePackageID(rawValue: "com.example.other"))
    let clientToken = SessionConnectionToken()
    let otherClientToken = SessionConnectionToken()
    let connectionID = ObjectIdentifier(clientToken)
    let otherConnectionID = ObjectIdentifier(otherClientToken)
    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: connectionID,
        frameReady: { _ in },
        closeRequested: { true }
    )
    let wrongSession = RestartAppRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: UUID(),
        packageID: package
    )
    let wrongPackage = RestartAppRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: opened.descriptor.sessionID,
        packageID: anotherPackage
    )
    let correctRequest = RestartAppRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: opened.descriptor.sessionID,
        packageID: package
    )

    for (request, owner, authorizedPackage) in [
        (wrongSession, connectionID, Optional(package)),
        (wrongPackage, connectionID, Optional(package)),
        (correctRequest, otherConnectionID, Optional(package)),
        (correctRequest, connectionID, Optional(anotherPackage)),
    ] {
        do {
            try await fixture.service.restartApp(
                request,
                from: owner,
                authorizedPackageID: authorizedPackage
            )
            Issue.record("A restart request outside the active session package binding was accepted.")
        } catch {
            #expect(error.code == "runtime.notAuthorized")
        }
    }
    #expect(await fixture.agent.stoppedPackages.isEmpty)
    #expect(await fixture.agent.launchCalls.count == 1)
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.state == .running)

    _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionRestartRestoresTheSessionWhenStopDoesNotComplete() async throws {
    let fixture = makeSessionServiceFixture(stopResults: [false, true])
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let clientToken = SessionConnectionToken()
    let connectionID = ObjectIdentifier(clientToken)
    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: connectionID,
        frameReady: { _ in },
        closeRequested: { true }
    )
    let request = RestartAppRequest(
        header: APIRequestHeader(clientKind: .launcher),
        sessionID: opened.descriptor.sessionID,
        packageID: package
    )

    do {
        try await fixture.service.restartApp(request, from: connectionID, authorizedPackageID: nil)
        Issue.record("A failed StopApplication should not relaunch the package.")
    } catch {
        #expect(error.code == "runtime.guestAgentOperationFailed")
    }
    #expect(await fixture.agent.launchCalls.count == 1)
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.state == .running)
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.taskIDs == [41])
    #expect(
        await fixture.registry.displayLease(.app(opened.descriptor.sessionID))?.androidDisplayID
            == opened.descriptor.displayID)

    _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionCloseGracefullyStopsTheAppAndReleasesItsDisplay() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let clientToken = SessionConnectionToken()
    let connectionID = ObjectIdentifier(clientToken)
    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: connectionID,
        frameReady: { _ in },
        closeRequested: { true }
    )
    let request = CloseSessionRequest(
        header: APIRequestHeader(clientKind: .launcher),
        sessionID: opened.descriptor.sessionID,
        packageID: package
    )

    try await fixture.service.closeSession(request, from: connectionID, authorizedPackageID: nil)

    #expect(
        await fixture.agent.sessionCallOrder == [
            "launch:\(opened.descriptor.displayID)",
            "stop:\(package.rawValue)",
        ])
    #expect(await fixture.agent.forceStoppedPackages.isEmpty)
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.state == .ended(.userClosed))
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
    await fixture.service.sessionClientDisconnected(connectionID)
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionCloseRejectsRequestsOutsideTheSessionBinding() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let anotherPackage = try #require(RuntimePackageID(rawValue: "com.example.other"))
    let clientToken = SessionConnectionToken()
    let otherClientToken = SessionConnectionToken()
    let connectionID = ObjectIdentifier(clientToken)
    let otherConnectionID = ObjectIdentifier(otherClientToken)
    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: connectionID,
        frameReady: { _ in },
        closeRequested: { true }
    )
    let wrongSession = CloseSessionRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: UUID(),
        packageID: package
    )
    let wrongPackage = CloseSessionRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: opened.descriptor.sessionID,
        packageID: anotherPackage
    )
    let correctRequest = CloseSessionRequest(
        header: APIRequestHeader(clientKind: .wrapper),
        sessionID: opened.descriptor.sessionID,
        packageID: package
    )

    for (request, owner, authorizedPackage) in [
        (wrongSession, connectionID, Optional(package)),
        (wrongPackage, connectionID, Optional(package)),
        (correctRequest, otherConnectionID, Optional(package)),
        (correctRequest, connectionID, Optional(anotherPackage)),
    ] {
        do {
            try await fixture.service.closeSession(
                request,
                from: owner,
                authorizedPackageID: authorizedPackage
            )
            Issue.record("A close request outside the active session package binding was accepted.")
        } catch {
            #expect(error.code == "runtime.notAuthorized")
        }
    }

    #expect(await fixture.agent.stoppedPackages.isEmpty)
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.state == .running)

    _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionCloseKeepsTheDisplayWhenStopDoesNotComplete() async throws {
    let fixture = makeSessionServiceFixture(stopResults: [false, true])
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let clientToken = SessionConnectionToken()
    let connectionID = ObjectIdentifier(clientToken)
    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: connectionID,
        frameReady: { _ in },
        closeRequested: { true }
    )
    let request = CloseSessionRequest(
        header: APIRequestHeader(clientKind: .launcher),
        sessionID: opened.descriptor.sessionID,
        packageID: package
    )

    do {
        try await fixture.service.closeSession(request, from: connectionID, authorizedPackageID: nil)
        Issue.record("A close must wait for the Guest Agent to finish app tasks.")
    } catch {
        #expect(error.code == "runtime.guestAgentOperationFailed")
    }
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.state == .running)
    #expect(await fixture.registry.session(.app(opened.descriptor.sessionID))?.taskIDs == [41])
    #expect((await fixture.displayPool.snapshot())[0].state == .allocated(.app(opened.descriptor.sessionID)))

    _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionResizeReplacesTheLeaseAndRelaysTheNewGeneration() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let clientToken = SessionConnectionToken()
    let connectionID = ObjectIdentifier(clientToken)
    let (frameStream, frameContinuation) = AsyncStream<FrameReady>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )
    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: connectionID,
        frameReady: { frameContinuation.yield($0) },
        closeRequested: { true }
    )
    let geometry = RuntimeAPI.DisplayGeometry(
        pointSize: DisplayPointSize(width: 520, height: 880),
        backingScale: 1,
        zoom: 1.25
    )
    let request = ResizeSessionRequest(
        header: APIRequestHeader(clientKind: .launcher),
        geometry: geometry
    )

    let outcome = try await fixture.service.resizeSession(request, from: connectionID)

    guard case .applied(let resized) = outcome else {
        Issue.record("Expected an applied resize result.")
        return
    }
    #expect(resized.descriptor.sessionID == opened.descriptor.sessionID)
    #expect(resized.descriptor.displayID == opened.descriptor.displayID)
    #expect(resized.descriptor.surfaces.generation > opened.descriptor.surfaces.generation)
    #expect(resized.descriptor.surfaces.pixelSize == RuntimeAPI.PixelSize(width: 520, height: 880))
    #expect(resized.surfaces.count == SurfaceSet.requiredSurfaceCount)

    let lease = await fixture.registry.displayLease(.app(opened.descriptor.sessionID))
    #expect(lease?.sessionPool.generation == UInt64(resized.descriptor.surfaces.generation))
    #expect(lease?.mode.pixelSize.width == 520)
    #expect(lease?.mode.pixelSize.height == 880)

    var frameIterator = frameStream.makeAsyncIterator()
    fixture.scanouts.sendFrame(scanout: 1, sequence: 28)
    let frame = try #require(await frameIterator.next())
    #expect(frame.generation == resized.descriptor.surfaces.generation)
    #expect(frame.frameSeq == 28)

    await fixture.service.frameDisplayed(
        FrameDisplayed(generation: frame.generation, frameSeq: frame.frameSeq),
        from: connectionID
    )
    #expect(fixture.scanouts.acknowledgedFrames == [28])
    let repeatedResize = try await fixture.service.resizeSession(request, from: connectionID)
    if case .unchanged = repeatedResize {
    } else {
        Issue.record("A repeated resize should return unchanged.")
    }

    _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionTakeoverClosesPreviousWindowBeforeChangingOwner() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let firstClient = SessionConnectionToken()
    let secondClient = SessionConnectionToken()
    let firstConnectionID = ObjectIdentifier(firstClient)
    let secondConnectionID = ObjectIdentifier(secondClient)
    let closeRequests = SessionCloseRequestRecorder(result: true)
    let (secondFrames, secondFrameContinuation) = AsyncStream<FrameReady>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )

    let first = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: firstConnectionID,
        frameReady: { _ in },
        closeRequested: { await closeRequests.request() }
    )
    let second = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: secondConnectionID,
        frameReady: { secondFrameContinuation.yield($0) },
        closeRequested: { true }
    )

    #expect(await closeRequests.count == 1)
    #expect(second.descriptor.sessionID == first.descriptor.sessionID)
    #expect(second.surfaces.count == SurfaceSet.requiredSurfaceCount)

    fixture.scanouts.sendFrame(scanout: 1, sequence: 31)
    var secondIterator = secondFrames.makeAsyncIterator()
    let frame = try #require(await secondIterator.next())
    #expect(frame.frameSeq == 31)
    await fixture.service.frameDisplayed(
        FrameDisplayed(generation: frame.generation, frameSeq: frame.frameSeq),
        from: secondConnectionID
    )
    await fixture.service.frameDisplayed(
        FrameDisplayed(generation: frame.generation, frameSeq: frame.frameSeq + 1),
        from: firstConnectionID
    )
    #expect(fixture.scanouts.acknowledgedFrames == [31])

    await fixture.service.sessionClientDisconnected(firstConnectionID)
    let terminated = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
    #expect(terminated.hadSession)
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionDoesNotTransferOwnershipWhenWindowCloseIsRejected() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))
    let firstClient = SessionConnectionToken()
    let secondClient = SessionConnectionToken()
    let firstConnectionID = ObjectIdentifier(firstClient)
    let secondConnectionID = ObjectIdentifier(secondClient)
    let closeRequests = SessionCloseRequestRecorder(result: false)
    let (firstFrames, firstFrameContinuation) = AsyncStream<FrameReady>.makeStream(
        bufferingPolicy: .bufferingNewest(1)
    )

    let opened = try await fixture.service.openSession(
        makeOpenSessionRequest(packageID: package),
        connectionID: firstConnectionID,
        frameReady: { firstFrameContinuation.yield($0) },
        closeRequested: { await closeRequests.request() }
    )
    do {
        _ = try await fixture.service.openSession(
            makeOpenSessionRequest(packageID: package),
            connectionID: secondConnectionID,
            frameReady: { _ in },
            closeRequested: { true }
        )
        Issue.record("A launcher that refused to close must retain session ownership.")
    } catch {
        #expect(error.code == "runtime.busy")
    }
    #expect(await closeRequests.count == 1)

    fixture.scanouts.sendFrame(scanout: 1, sequence: 37)
    var firstIterator = firstFrames.makeAsyncIterator()
    let frame = try #require(await firstIterator.next())
    #expect(frame.generation == opened.descriptor.surfaces.generation)
    await fixture.service.frameDisplayed(
        FrameDisplayed(generation: frame.generation, frameSeq: frame.frameSeq),
        from: firstConnectionID
    )
    #expect(fixture.scanouts.acknowledgedFrames == [37])

    await fixture.service.sessionClientDisconnected(secondConnectionID)
    _ = try await fixture.service.terminate(RuntimeTerminateRequest(packageID: package))
}

@Test
func daemonTerminateWithoutSessionForceStopsWithoutAllocatingADisplay() async throws {
    let fixture = makeSessionServiceFixture()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    let result = try await DaemonSessionService.terminateWithoutSession(
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
    let fixture = makeSessionServiceFixture(isInstalled: false)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await DaemonSessionService.terminateWithoutSession(
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
func daemonSessionServiceDoesNotBlockAnImmediateGuestSnapshot() async throws {
    let fixture = makeSessionServiceFixture(
        snapshotOnRegistration: guestSnapshot(displays: [0])
    )
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    let launched = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))

    #expect(launched.state == .running)
    #expect(await fixture.agent.launchCalls.count == 1)
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionServiceRejectsMissingPackageBeforeAllocatingDisplay() async throws {
    let fixture = makeSessionServiceFixture(isInstalled: false)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
        Issue.record("An uninstalled package must not acquire an app display.")
    } catch {
        #expect(error.code == "runtime.packageNotInstalled")
    }

    #expect(fixture.scanouts.configuredScanouts.isEmpty)
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
    #expect(await fixture.registry.session(packageID: package.rawValue) == nil)
}

@Test(.timeLimit(.minutes(1)))
func daemonSessionTerminationKeepsLeaseUntilGuestConfirmsTasksStopped() async throws {
    let fixture = makeSessionServiceFixture(stopResults: [false, true])
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
func daemonSessionServiceReleasesItsLeaseWhenTheGuestTaskVanishes() async throws {
    let fixture = makeSessionServiceFixture()
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
func daemonSessionServiceReconcilesItsTaskAndReleasesLeaseAfterReconnect() async throws {
    let fixture = makeSessionServiceFixture()
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
func daemonSessionShutdownClosesTheServiceBeforeFurtherLaunches() async throws {
    let fixture = makeSessionServiceFixture()
    await fixture.service.shutdown()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await fixture.service.launch(RuntimeLaunchRequest(packageID: package))
        Issue.record("A stopped session service accepted a new launch.")
    } catch {
        #expect(error.code == "runtime.hostShuttingDown")
    }

    #expect(await fixture.agent.launchCalls.isEmpty)
    #expect((await fixture.displayPool.snapshot())[0].state == .free)
}

private func makeOpenSessionRequest(packageID: RuntimePackageID) -> OpenSessionRequest {
    OpenSessionRequest(
        header: APIRequestHeader(clientKind: .launcher),
        packageID: packageID,
        geometry: RuntimeAPI.DisplayGeometry(
            pointSize: DisplayPointSize(width: 480, height: 850),
            backingScale: 1,
            zoom: 1.25
        ),
        screenSize: DisplayPointSize(width: 1280, height: 900)
    )
}

private final class SessionConnectionToken {}

private actor SessionCloseRequestRecorder {
    private let result: Bool
    private(set) var count = 0

    init(result: Bool) {
        self.result = result
    }

    func request() -> Bool {
        count += 1
        return result
    }
}

private struct SessionServiceFixture {
    let service: DaemonSessionService
    let registry: SessionRegistry
    let displayPool: DisplayPool
    let agent: FakeDaemonSessionGuestAgent
    let scanouts: FakeSessionScanoutController
}

private func makeSessionServiceFixture(
    isInstalled: Bool = true,
    stopResults: [Bool] = [true],
    snapshotOnRegistration: GuestSnapshotState? = nil
) -> SessionServiceFixture {
    let displayControl = FakeSessionDisplayControlChannel()
    let scanouts = FakeSessionScanoutController(guest: displayControl)
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
    let agent = FakeDaemonSessionGuestAgent(
        isInstalled: isInstalled,
        stopResults: stopResults,
        snapshotOnRegistration: snapshotOnRegistration
    )
    let service = DaemonSessionService(
        guestAgent: agent,
        displayPool: displayPool,
        registry: registry,
        displayConfiguration: DisplayConfiguration(
            geometry: DisplayGeometry(
                pointSize: CGSize(width: 480, height: 850),
                backingScale: 1
            )
        )
    )
    return SessionServiceFixture(
        service: service,
        registry: registry,
        displayPool: displayPool,
        agent: agent,
        scanouts: scanouts
    )
}

private struct SessionLaunchCall: Sendable, Equatable {
    let packageID: String
    let displayID: Int32
}

private actor FakeDaemonSessionGuestAgent: DaemonSessionGuestAgent {
    private let installed: Bool
    private var stopResults: [Bool]
    private let snapshotOnRegistration: GuestSnapshotState?
    private(set) var launchCalls: [SessionLaunchCall] = []
    private(set) var stoppedPackages: [String] = []
    private(set) var forceStoppedPackages: [String] = []
    private(set) var sessionCallOrder: [String] = []
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
        launchCalls.append(SessionLaunchCall(packageID: package, displayID: displayID))
        sessionCallOrder.append("launch:\(displayID)")
        return GuestLaunchReport(
            taskID: 41,
            component: "\(package)/.MainActivity",
            outcome: "started"
        )
    }

    func stopApplication(package: String) async throws(GuestAgentFailure) -> Bool {
        stoppedPackages.append(package)
        sessionCallOrder.append("stop:\(package)")
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

private final class FakeSessionDisplayControlChannel: DisplayControlChannel, @unchecked Sendable {
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

private final class FakeSessionScanoutController: ScanoutController, @unchecked Sendable {
    private let lock = NSLock()
    private let guest: FakeSessionDisplayControlChannel
    private var displaysByScanout: [Int: Int32] = [:]
    private var continuations: [Int: AsyncStream<ScanoutFrame>.Continuation] = [:]
    private var poolGenerations: [Int: UInt64] = [:]
    private var generation: UInt64 = 0
    private var acknowledged: [UInt64] = []
    private var configured: [Int] = []

    init(guest: FakeSessionDisplayControlChannel) {
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
            uniqueID: "session-scanout-\(scanout.rawValue)",
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
        try makePool(scanout, width: width, height: height)
    }

    func reconfigure(
        _ scanout: ScanoutID,
        mode: DisplayMode,
        width: Int,
        height: Int
    ) throws(GraphicsFailure) -> ScanoutPoolHandle {
        try makePool(scanout, width: width, height: height)
    }

    func detachPool(_ scanout: ScanoutID, generation: UInt64?) {
        let detached = lock.withLock { () -> AsyncStream<ScanoutFrame>.Continuation? in
            guard generation == nil || poolGenerations[scanout.rawValue] == generation else {
                return nil
            }
            poolGenerations[scanout.rawValue] = nil
            return continuations.removeValue(forKey: scanout.rawValue)
        }
        detached?.finish()
    }

    func sendFrame(scanout: Int, sequence: UInt64) {
        let (continuation, generation) = lock.withLock {
            (continuations[scanout], poolGenerations[scanout])
        }
        guard let generation else { return }
        continuation?.yield(.frameReady(generation: generation, bufferIndex: 0, sequence: sequence))
    }

    private func makePool(_ scanout: ScanoutID, width: Int, height: Int) throws(GraphicsFailure)
        -> ScanoutPoolHandle
    {
        var surfaces: [IOSurface] = []
        surfaces.reserveCapacity(SurfaceSet.requiredSurfaceCount)
        for _ in 0..<SurfaceSet.requiredSurfaceCount {
            guard
                let surface = IOSurface(
                    properties: [
                        .width: width,
                        .height: height,
                        .bytesPerElement: 4,
                        .bytesPerRow: ((width * 4 + 63) / 64) * 64,
                    ]
                )
            else {
                throw GraphicsFailure.rendererOperationFailed(
                    operation: "testIOSurfaceAllocation",
                    detail: "The session test could not allocate a surface."
                )
            }
            surfaces.append(surface)
        }
        let (frames, continuation) = AsyncStream<ScanoutFrame>.makeStream()
        let (poolGeneration, previousContinuation) = lock.withLock {
            () -> (UInt64, AsyncStream<ScanoutFrame>.Continuation?) in
            generation &+= 1
            let oldContinuation = continuations[scanout.rawValue]
            continuations[scanout.rawValue] = continuation
            poolGenerations[scanout.rawValue] = generation
            return (generation, oldContinuation)
        }
        previousContinuation?.finish()
        return ScanoutPoolHandle(
            generation: poolGeneration,
            surfaces: surfaces,
            frames: frames,
            acknowledgeFrame: { [self] sequence in
                lock.withLock { acknowledged.append(sequence) }
            }
        )
    }
}
