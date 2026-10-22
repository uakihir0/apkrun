import CoreGraphics
import Foundation
import GuestProtocol
import RuntimeAPI
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test
func developerDisplayResolvesTheInitialRetinaAndNonRetinaModes() throws {
    let retina = try DeveloperDisplay(
        pointSize: CGSize(width: 480, height: 850),
        backingScale: 2
    )
    let nonRetina = try DeveloperDisplay(
        pointSize: CGSize(width: 480, height: 850),
        backingScale: 1
    )

    #expect(retina.pixelWidth == 960)
    #expect(retina.pixelHeight == 1700)
    #expect(retina.mode.densityDpi == 320)
    #expect(retina.backingScale == 2)
    #expect(nonRetina.pixelWidth == 480)
    #expect(nonRetina.pixelHeight == 850)
    #expect(nonRetina.mode.densityDpi == 160)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceTracksLaunchFrameCloseAndTaskVanished() async throws {
    let service = EmbeddedRuntimeService()

    let requested = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    #expect(requested.state == .waitingForRuntime)
    #expect(requested.displayID == 0)

    let displayReady = try await service.displayReady()
    #expect(displayReady.state == .acquiringDisplay)
    #expect(try EmbeddedRuntimeService.launchResult(for: displayReady).state == .acquiringDisplay)
    let launching = try await service.beginLaunch()
    #expect(launching.state == .launching)

    let launched = try await service.launched(taskID: 19)
    #expect(launched.taskIDs == [19])
    let running = try await service.firstFramePresented()
    #expect(running.state == .running)

    let closing = try await service.windowClosed()
    #expect(closing.state == .closing)
    #expect(try EmbeddedRuntimeService.launchResult(for: closing).state == .closing)
    let ended = await service.taskVanished()
    #expect(ended?.state == .ended(.userClosed))
    #expect(try await service.runtimeStopped() == nil)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceEndsWhenTheLastGuestTaskVanishes() async throws {
    let service = EmbeddedRuntimeService()
    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()
    _ = try await service.launched(taskID: 19)
    _ = await service.taskEvent(.appeared(packageID: "io.apkrun.fixture.hellotext", taskID: 20))
    _ = try await service.firstFramePresented()

    let unrelated = await service.taskEvent(.vanished(packageID: "io.apkrun.fixture.hellocompose", taskID: 19))
    let firstVanished = await service.taskEvent(.vanished(packageID: "io.apkrun.fixture.hellotext", taskID: 19))
    let lastVanished = await service.taskEvent(.vanished(packageID: "io.apkrun.fixture.hellotext", taskID: 20))

    #expect(unrelated == nil)
    #expect(firstVanished?.state == .running)
    #expect(firstVanished?.taskIDs == [20])
    #expect(lastVanished?.state == .ended(.appExited))
    #expect(lastVanished?.taskIDs.isEmpty == true)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServicePreservesTaskExitBeforeLaunchReply() async throws {
    let service = EmbeddedRuntimeService()
    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()

    _ = await service.taskEvent(.appeared(packageID: "io.apkrun.fixture.hellotext", taskID: 19))
    let ended = await service.taskEvent(.vanished(packageID: "io.apkrun.fixture.hellotext", taskID: 19))
    let launchReply = try await service.launched(taskID: 19)

    #expect(ended?.state == .launching)
    #expect(launchReply.state == .ended(.appExited))
    #expect(launchReply.taskIDs.isEmpty)
    #expect(await service.currentSession() == launchReply)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceKeepsLaunchAliveWhenAnEarlierPackageTaskVanishes() async throws {
    let service = EmbeddedRuntimeService()
    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()

    _ = await service.taskEvent(.appeared(packageID: "io.apkrun.fixture.hellotext", taskID: 18))
    let earlierTaskVanished = await service.taskEvent(
        .vanished(packageID: "io.apkrun.fixture.hellotext", taskID: 18)
    )
    let launchReply = try await service.launched(taskID: 19)

    #expect(earlierTaskVanished?.state == .launching)
    #expect(launchReply.state == .launching)
    #expect(launchReply.taskIDs == [19])
    #expect(try await service.firstFramePresented().state == .running)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceReconcilesAnUntrackedVanishWithTheLaunchReply() async throws {
    let service = EmbeddedRuntimeService()
    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()

    let vanished = await service.taskEvent(
        .vanished(packageID: "io.apkrun.fixture.hellotext", taskID: 19)
    )
    let launchReply = try await service.launched(taskID: 19)

    #expect(vanished?.state == .launching)
    #expect(launchReply.state == .ended(.appExited))
    #expect(launchReply.taskIDs.isEmpty)
    #expect(await service.currentSession() == launchReply)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceImplementsRuntimeLaunchAndTerminate() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let stopSignal = DevBootStopSignal()
    let service = EmbeddedRuntimeService(developerDisplay: display, stopSignal: stopSignal)
    await service.attachGuestAgent(guest)
    let runtime: any RuntimeSessionService = service
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    let launchTask = Task {
        try await runtime.launch(RuntimeLaunchRequest(packageID: package))
    }
    for _ in 0..<100 {
        if await guest.launchedPackages.count == 1 {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await guest.launchedPackages == [package.rawValue])
    display.frameDisplayed(sequence: 1)

    let launched = try await launchTask.value
    #expect(launched.packageID == package)
    #expect(launched.state == .running)
    let terminated = try await runtime.terminate(RuntimeTerminateRequest(packageID: package))
    #expect(terminated.hadSession)
    #expect(await service.currentSession()?.state == .ended(.userClosed))

    let unmanaged = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellocompose"))
    let stoppedWithoutSession = try await runtime.terminate(RuntimeTerminateRequest(packageID: unmanaged))
    #expect(!stoppedWithoutSession.hadSession)
    #expect(await guest.forceStoppedPackages == [package.rawValue, unmanaged.rawValue])
    display.finish()
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceEndsAnActiveSessionBeforePackageUninstall() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let service = EmbeddedRuntimeService()
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    _ = try await service.requestSession(packageID: package.rawValue)
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()
    _ = try await service.launched(taskID: 23)
    _ = try await service.firstFramePresented()

    try await service.endSessionForPackageUninstall(RuntimeTerminateRequest(packageID: package))

    #expect(await service.currentSession()?.state == .ended(.packageUninstalled))
    #expect(await guest.forceStoppedPackages == [package.rawValue])
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceDoesNotRequireAGuestAgentWhenUninstallHasNoSession() async throws {
    let service = EmbeddedRuntimeService()
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    try await service.endSessionForPackageUninstall(RuntimeTerminateRequest(packageID: package))

    #expect(await service.currentSession() == nil)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceRejectsLaunchWithoutAWindow() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let service = EmbeddedRuntimeService()
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    await #expect(
        throws: RuntimeWireError.runtime(
            "windowUnavailable",
            message: "APKRun couldn't open an Android app window.",
            remediation: "Start the app from APKRun or use a window-backed runtime session."
        )
    ) {
        try await service.launch(RuntimeLaunchRequest(packageID: package))
    }

    #expect(await guest.launchedPackages.isEmpty)
    #expect(await service.currentSession() == nil)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceDoesNotClaimToStopAnUninstalledPackage() async throws {
    let guest = FakeEmbeddedSessionGuestAgent(isInstalled: false)
    let service = EmbeddedRuntimeService()
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await service.terminate(RuntimeTerminateRequest(packageID: package))
        Issue.record("Terminate must reject a package that Android does not have installed.")
    } catch {
        #expect(error.code == "runtime.packageNotInstalled")
    }

    #expect(await guest.forceStoppedPackages.isEmpty)
    #expect(await service.currentSession() == nil)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceRejectsAnotherPackageWhileTheWindowSessionIsOwned() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let service = EmbeddedRuntimeService()
    await service.attachGuestAgent(guest)
    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellocompose"))

    await #expect(
        throws: RuntimeWireError.runtime(
            "sessionAlreadyExists",
            message: "io.apkrun.fixture.hellotext already has a live app session on another display.",
            remediation: "Close its current window before requesting another display."
        )
    ) {
        try await service.launch(RuntimeLaunchRequest(packageID: package))
    }

    #expect(await guest.launchedPackages.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceRejectsLaunchOfUninstalledPackage() async throws {
    let guest = FakeEmbeddedSessionGuestAgent(isInstalled: false)
    let service = EmbeddedRuntimeService()
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await service.launch(RuntimeLaunchRequest(packageID: package))
        Issue.record("Runtime launch must check Android package inventory.")
    } catch {
        #expect(error.code == "runtime.packageNotInstalled")
    }
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceClosesASessionTerminatedBeforeLaunch() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let service = EmbeddedRuntimeService()
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    _ = try await service.requestSession(packageID: package.rawValue)
    let result = try await service.terminate(RuntimeTerminateRequest(packageID: package))

    #expect(result.hadSession)
    #expect(await service.currentSession()?.state == .ended(.userClosed))
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceRestoresSessionWhenGuestCannotStopTasks() async throws {
    let guest = FakeEmbeddedSessionGuestAgent(stopResult: false)
    let service = EmbeddedRuntimeService()
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    _ = try await service.requestSession(packageID: package.rawValue)
    do {
        _ = try await service.terminate(RuntimeTerminateRequest(packageID: package))
        Issue.record("Termination must not succeed while Android still reports package tasks.")
    } catch {
        #expect(error.code == "runtime.guestAgentOperationFailed")
    }

    #expect(await service.currentSession()?.state == .waitingForRuntime)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceClosesAnUnlaunchedWindowWithoutStoppingItsPackage() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let service = EmbeddedRuntimeService()
    await service.attachGuestAgent(guest)
    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")

    try await service.closeForWindow()

    #expect(await service.currentSession()?.state == .ended(.runtimeStopped))
    #expect(await guest.stoppedPackages.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceReconcilesTerminalGuestSnapshotThroughMultiWindowCallback() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let stopSignal = DevBootStopSignal()
    let reconciled = ReconciliationResultLog()
    let service = EmbeddedRuntimeService(
        developerDisplay: display,
        stopSignal: stopSignal,
        onTerminalSessionReconciled: { await reconciled.append($0) }
    )
    defer { display.finish() }

    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()
    _ = try await service.launched(taskID: 23)
    _ = try await service.firstFramePresented()
    await service.attachGuestAgent(guest)

    await guest.resynchronize(with: guestSnapshot(displays: [0]))

    let results = await reconciled.results
    #expect(results.count == 1)
    #expect(results.first?.state == .ended(.appExited))
    #expect(await service.currentSession()?.state == .ended(.appExited))
    #expect(await stopSignal.current() == nil)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceSignalsSingleWindowWhenSnapshotShowsAppExited() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let stopSignal = DevBootStopSignal()
    let service = EmbeddedRuntimeService(developerDisplay: display, stopSignal: stopSignal)
    defer { display.finish() }

    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()
    _ = try await service.launched(taskID: 23)
    _ = try await service.firstFramePresented()
    await service.attachGuestAgent(guest)

    await guest.resynchronize(with: guestSnapshot(displays: [0]))

    #expect(await service.currentSession()?.state == .ended(.appExited))
    #expect(await stopSignal.current() == .appExited)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceStopsSingleWindowAfterSnapshotLosesItsDisplay() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let stopSignal = DevBootStopSignal()
    let service = EmbeddedRuntimeService(developerDisplay: display, stopSignal: stopSignal)
    defer { display.finish() }

    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()
    _ = try await service.launched(taskID: 23)
    _ = try await service.firstFramePresented()
    await service.attachGuestAgent(guest)

    await guest.resynchronize(with: guestSnapshot(displays: []))

    #expect(await service.currentSession()?.state == .ended(.error(.displayLost)))
    #expect(await stopSignal.current() == .appWindowCloseFailed)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceRelaunchesMissingLaunchingTaskWithoutWaitingForFrame() async throws {
    let guest = FakeEmbeddedSessionGuestAgent()
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let service = EmbeddedRuntimeService(
        developerDisplay: display,
        stopSignal: DevBootStopSignal()
    )
    defer { display.finish() }

    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()
    await service.attachGuestAgent(guest)

    await guest.resynchronize(with: guestSnapshot(displays: [0]))
    for _ in 0..<100 {
        if await guest.launchedPackages.count == 1 {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await guest.launchedPackages == ["io.apkrun.fixture.hellotext"])
    #expect(await service.currentSession()?.state == .launching)
    #expect(await service.currentSession()?.taskIDs == [23])

    display.frameDisplayed(sequence: 1)
    for _ in 0..<100 {
        if await service.currentSession()?.state == .running {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.currentSession()?.state == .running)
}

@Test(.timeLimit(.minutes(1)))
func embeddedRuntimeServiceFinishesLaunchWhenSnapshotAlreadyContainsItsTask() async throws {
    let guest = FakeEmbeddedSessionGuestAgent(
        launchFailures: [.operationFailed(reason: "disconnected")]
    )
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let service = EmbeddedRuntimeService(
        developerDisplay: display,
        stopSignal: DevBootStopSignal()
    )
    defer { display.finish() }
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await service.launch(RuntimeLaunchRequest(packageID: package))
        Issue.record("the first Guest Agent launch should report its simulated lost reply")
    } catch {
        #expect(error.code == "runtime.guestAgentOperationFailed")
    }
    #expect(await service.currentSession()?.state == .launching)

    await guest.resynchronize(
        with: guestSnapshot(
            displays: [0],
            tasks: [(taskID: 23, displayID: 0, packageID: package.rawValue)]
        )
    )

    #expect(await guest.launchedPackages == [package.rawValue])
    #expect(await service.currentSession()?.state == .launching)
    #expect(await service.currentSession()?.taskIDs == [23])

    display.frameDisplayed(sequence: 1)
    for _ in 0..<100 {
        if await service.currentSession()?.state == .running {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await service.currentSession()?.state == .running)
    #expect(await guest.launchedPackages == [package.rawValue])
}

@Test(.timeLimit(.minutes(1)))
func transientLaunchDisconnectStaysReconcilableAndRelaunchesFromSnapshot() async throws {
    let guest = FakeEmbeddedSessionGuestAgent(
        launchFailures: [.operationFailed(reason: "agentUnavailable.guestAgent")]
    )
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let stopSignal = DevBootStopSignal()
    let service = EmbeddedRuntimeService(developerDisplay: display, stopSignal: stopSignal)
    defer { display.finish() }
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    let launch = try await service.launch(RuntimeLaunchRequest(packageID: package))
    #expect(launch.state == .launching)
    #expect(await service.currentSession()?.state == .launching)
    #expect(await service.currentSession()?.taskIDs.isEmpty == true)

    await guest.resynchronize(with: guestSnapshot(displays: [0]))
    for _ in 0..<100 {
        if await guest.launchedPackages.count == 2 {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await guest.launchedPackages.count == 2)
    #expect(await service.currentSession()?.state == .launching)
    #expect(await service.currentSession()?.taskIDs == [23])
    #expect(await stopSignal.current() == nil)

    display.frameDisplayed(sequence: 1)
    for _ in 0..<100 {
        if await service.currentSession()?.state == .running {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await service.currentSession()?.state == .running)
}

@Test(.timeLimit(.minutes(1)))
func exhaustedAgentRestartBudgetEndsDeferredLaunch() async throws {
    let guest = FakeEmbeddedSessionGuestAgent(
        launchFailures: [
            .operationFailed(reason: "disconnected"),
            .requiredAgentUnavailable,
        ]
    )
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let stopSignal = DevBootStopSignal()
    let service = EmbeddedRuntimeService(developerDisplay: display, stopSignal: stopSignal)
    defer { display.finish() }
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    _ = try await service.launch(RuntimeLaunchRequest(packageID: package))
    await guest.resynchronize(with: guestSnapshot(displays: [0]))

    for _ in 0..<100 {
        if await service.currentSession()?.state == .ended(.error(.runtimeFailed)) {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await guest.launchedPackages.count == 2)
    #expect(await service.currentSession()?.state == .ended(.error(.runtimeFailed)))
    #expect(await stopSignal.current() == .appWindowCloseFailed)
}

@Test(.timeLimit(.minutes(1)))
func remoteLaunchRejectionStillEndsTheFailedSession() async throws {
    let guest = FakeEmbeddedSessionGuestAgent(
        launchFailures: [.operationFailed(reason: "remote.launchApplication.INVALID_ARGUMENT")]
    )
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let service = EmbeddedRuntimeService(
        developerDisplay: display,
        stopSignal: DevBootStopSignal()
    )
    defer { display.finish() }
    await service.attachGuestAgent(guest)
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

    do {
        _ = try await service.launch(RuntimeLaunchRequest(packageID: package))
        Issue.record("the simulated remote rejection must fail the launch")
    } catch {
        #expect(error.code == "runtime.guestAgentOperationFailed")
    }

    #expect(await service.currentSession()?.state == .ended(.error(.runtimeFailed)))
}

@Test(.timeLimit(.minutes(1)))
func failedSnapshotRelaunchNotifiesTheWindowOwner() async throws {
    let guest = FakeEmbeddedSessionGuestAgent(
        launchFailures: [.operationFailed(reason: "remote.launchApplication.INVALID_ARGUMENT")]
    )
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let reconciled = ReconciliationResultLog()
    let service = EmbeddedRuntimeService(
        developerDisplay: display,
        stopSignal: DevBootStopSignal(),
        onTerminalSessionReconciled: { await reconciled.append($0) }
    )
    defer { display.finish() }

    _ = try await service.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()
    await service.attachGuestAgent(guest)

    await guest.resynchronize(with: guestSnapshot(displays: [0]))
    for _ in 0..<100 {
        if await reconciled.results.count == 1 {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(await reconciled.results.first?.state == .ended(.error(.runtimeFailed)))
    #expect(await service.currentSession()?.state == .ended(.error(.runtimeFailed)))
}

@Test(.timeLimit(.minutes(1)))
func embeddedMultiSessionServiceTerminatesOnlyTheOwningWindow() async throws {
    let firstGuest = FakeEmbeddedSessionGuestAgent()
    let secondGuest = FakeEmbeddedSessionGuestAgent()
    let first = EmbeddedRuntimeService()
    let second = EmbeddedRuntimeService()
    await first.attachGuestAgent(firstGuest)
    await second.attachGuestAgent(secondGuest)
    _ = try await first.requestSession(packageID: "io.apkrun.fixture.hellotext")
    _ = try await second.requestSession(packageID: "io.apkrun.fixture.hellocompose")
    let sessions = EmbeddedMultiSessionService(
        sessions: [
            "io.apkrun.fixture.hellotext": first,
            "io.apkrun.fixture.hellocompose": second,
        ]
    )
    let package = try #require(RuntimePackageID(rawValue: "io.apkrun.fixture.hellocompose"))

    let result = try await sessions.terminate(RuntimeTerminateRequest(packageID: package))

    #expect(result.hadSession)
    #expect(await first.currentSession()?.state == .waitingForRuntime)
    #expect(await second.currentSession()?.state == .ended(.userClosed))
    #expect(await firstGuest.stoppedPackages.isEmpty)
    #expect(await secondGuest.forceStoppedPackages == [package.rawValue])
}

@Test(.timeLimit(.minutes(1)))
func devBootMultiWindowCoordinatorStopsOnlyAfterEveryWindowCloses() async throws {
    let firstDisplay = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let secondDisplay = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let (firstCloseRequests, firstCloseContinuation) = AsyncStream.makeStream(of: Void.self)
    let (secondCloseRequests, secondCloseContinuation) = AsyncStream.makeStream(of: Void.self)
    let firstPackage = "io.apkrun.fixture.hellotext"
    let secondPackage = "io.apkrun.fixture.hellocompose"
    let first = DevBootAppLaunch(
        packageID: firstPackage,
        apkURL: nil,
        display: firstDisplay,
        displayMode: .primaryDisplayCompatibility,
        inputRoute: DevInputRoute(),
        closeRequests: firstCloseRequests
    )
    let second = DevBootAppLaunch(
        packageID: secondPackage,
        apkURL: nil,
        display: secondDisplay,
        displayMode: .secondaryDisplay,
        inputRoute: DevInputRoute(),
        closeRequests: secondCloseRequests
    )
    let signal = DevBootStopSignal()
    let coordinator = DevBootMultiWindowCoordinator(
        launches: [first, second],
        stopSignal: signal,
        report: { _ in }
    )
    defer {
        firstCloseContinuation.finish()
        secondCloseContinuation.finish()
        firstDisplay.finish()
        secondDisplay.finish()
    }

    await coordinator.closeWindow(for: firstPackage)
    #expect(await first.windowState.isClosed())
    #expect(!(await second.windowState.isClosed()))
    #expect(await signal.current() == nil)

    await coordinator.closeWindow(for: secondPackage)
    #expect(await second.windowState.isClosed())
    #expect(await signal.current() == .appWindowClosed)
}

@Test(.timeLimit(.minutes(1)))
func devBootObservesWindowClosesBeforeAndroidIsReady() async throws {
    let firstDisplay = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let secondDisplay = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let (firstCloseRequests, firstCloseContinuation) = AsyncStream.makeStream(of: Void.self)
    let (secondCloseRequests, secondCloseContinuation) = AsyncStream.makeStream(of: Void.self)
    let first = DevBootAppLaunch(
        packageID: "io.apkrun.fixture.hellotext",
        apkURL: nil,
        display: firstDisplay,
        displayMode: .primaryDisplayCompatibility,
        inputRoute: DevInputRoute(),
        closeRequests: firstCloseRequests
    )
    let second = DevBootAppLaunch(
        packageID: "io.apkrun.fixture.hellocompose",
        apkURL: nil,
        display: secondDisplay,
        displayMode: .secondaryDisplay,
        inputRoute: DevInputRoute(),
        closeRequests: secondCloseRequests
    )
    let signal = DevBootStopSignal()
    let coordinator = DevBootMultiWindowCoordinator(
        launches: [first, second],
        stopSignal: signal,
        report: { _ in }
    )
    let monitors = DevBoot.observeAppWindowCloseRequests(
        launches: [first, second],
        coordinator: coordinator
    )
    defer {
        for monitor in monitors {
            monitor.cancel()
        }
        firstCloseContinuation.finish()
        secondCloseContinuation.finish()
        firstDisplay.finish()
        secondDisplay.finish()
    }

    firstCloseContinuation.yield(())
    secondCloseContinuation.yield(())

    #expect(await signal.wait() == .appWindowClosed)
    #expect(await first.windowState.isClosed())
    #expect(await second.windowState.isClosed())
}

@Test(.timeLimit(.minutes(1)))
func devBootClosesWindowWhenReconnectSnapshotLosesItsDisplay() async throws {
    let package = "io.apkrun.fixture.hellotext"
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let (closeRequests, closeContinuation) = AsyncStream.makeStream(of: Void.self)
    let launch = DevBootAppLaunch(
        packageID: package,
        apkURL: nil,
        display: display,
        displayMode: .primaryDisplayCompatibility,
        inputRoute: DevInputRoute(),
        closeRequests: closeRequests
    )
    let (events, eventContinuation) = AsyncStream.makeStream(of: DevBootEvent.self)
    let coordinator = DevBootMultiWindowCoordinator(
        launches: [launch],
        stopSignal: DevBootStopSignal(),
        report: { eventContinuation.yield($0) }
    )
    let registry = SessionRegistry()
    let session = try await registry.request(packageID: package)
    _ = try await registry.transition(session.id, to: .waitingForRuntime)
    _ = try await registry.transition(session.id, to: .acquiringDisplay)
    _ = try await registry.transition(session.id, to: .launching)
    _ = await registry.launchCompleted(packageID: package, taskID: 23)
    _ = try await registry.transition(session.id, to: .running)
    let lostDisplay = try await registry.reconcile(sessionID: session.id, against: GuestSnapshotState())
    defer {
        closeContinuation.finish()
        eventContinuation.finish()
        display.finish()
    }

    await coordinator.reconcileTerminalSession(lostDisplay.session)
    eventContinuation.finish()
    var reportedEvents: [DevBootEvent] = []
    for await event in events {
        reportedEvents.append(event)
    }

    #expect(await launch.windowState.isClosed())
    #expect(
        reportedEvents.contains {
            if case .appWindowExited(packageID: package) = $0 { true } else { false }
        }
    )
    #expect(
        reportedEvents.contains {
            if case .warning = $0 { true } else { false }
        }
    )
}

@Test(.timeLimit(.minutes(1)))
func devBootStopsTheRuntimeWhenAClosedWindowCannotStopItsApp() async throws {
    let package = "io.apkrun.fixture.hellotext"
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    let (closeRequests, closeContinuation) = AsyncStream.makeStream(of: Void.self)
    let launch = DevBootAppLaunch(
        packageID: package,
        apkURL: nil,
        display: display,
        displayMode: .primaryDisplayCompatibility,
        inputRoute: DevInputRoute(),
        closeRequests: closeRequests
    )
    let signal = DevBootStopSignal()
    let stopProbe = DevBootStopProbe()
    await signal.attachStopHandler {
        await stopProbe.record("stop")
    }
    #expect(await signal.beginDisplayAcquisition())
    let coordinator = DevBootMultiWindowCoordinator(
        launches: [launch],
        stopSignal: signal,
        report: { _ in }
    )
    let guest = FakeEmbeddedSessionGuestAgent(stopResult: false)
    let service = EmbeddedRuntimeService(developerDisplay: display, stopSignal: signal)
    await service.attachGuestAgent(guest)
    _ = try await service.requestSession(packageID: package)
    _ = try await service.displayReady()
    _ = try await service.beginLaunch()
    _ = try await service.launched(taskID: 23)
    _ = try await service.firstFramePresented()
    #expect(await coordinator.register(service, for: package))
    defer {
        closeContinuation.finish()
        display.finish()
    }

    await coordinator.closeWindow(for: package)
    #expect(!(await signal.hasScheduledRuntimeStop()))
    #expect(await service.currentSession()?.state == .running)
    await coordinator.stopAllWindows()
    await signal.stopRuntime()

    #expect(await signal.current() == .appWindowCloseFailed)
    #expect(await stopProbe.events == ["stop"])
    #expect(await service.currentSession()?.state == .ended(.runtimeStopped))
}

private actor FakeEmbeddedSessionGuestAgent: EmbeddedSessionGuestAgent {
    private let installed: Bool
    private let stopResult: Bool
    private var launchFailures: [GuestAgentFailure]
    private(set) var launchedPackages: [String] = []
    private(set) var stoppedPackages: [String] = []
    private(set) var forceStoppedPackages: [String] = []
    private var resynchronizationHandlerID: UUID?
    private var resynchronizationHandler: (@Sendable (GuestSnapshotState) async -> Void)?

    init(
        isInstalled: Bool = true,
        stopResult: Bool = true,
        launchFailures: [GuestAgentFailure] = []
    ) {
        installed = isInstalled
        self.stopResult = stopResult
        self.launchFailures = launchFailures
    }

    func isInstalled(_ package: String) async throws(GuestAgentFailure) -> Bool {
        installed
    }

    func launch(package: String, displayID: Int32) async throws(GuestAgentFailure) -> GuestLaunchReport {
        launchedPackages.append(package)
        if !launchFailures.isEmpty {
            throw launchFailures.removeFirst()
        }
        return GuestLaunchReport(taskID: 23, component: "\(package)/.MainActivity", outcome: "started")
    }

    func stopApplication(package: String) async throws(GuestAgentFailure) -> Bool {
        stoppedPackages.append(package)
        return stopResult
    }

    func forceStopApplication(package: String) async throws(GuestAgentFailure) -> Bool {
        forceStoppedPackages.append(package)
        return stopResult
    }

    func addResynchronizationHandler(
        _ handler: @escaping @Sendable (GuestSnapshotState) async -> Void
    ) async -> UUID {
        let id = UUID()
        resynchronizationHandlerID = id
        resynchronizationHandler = handler
        return id
    }

    func removeResynchronizationHandler(_ id: UUID) async {
        guard resynchronizationHandlerID == id else {
            return
        }
        resynchronizationHandlerID = nil
        resynchronizationHandler = nil
    }

    func resynchronize(with snapshot: GuestSnapshotState) async {
        await resynchronizationHandler?(snapshot)
    }
}

private actor ReconciliationResultLog {
    private(set) var results: [AppSessionSnapshot] = []

    func append(_ result: AppSessionSnapshot) {
        results.append(result)
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

@Test(.timeLimit(.minutes(1)))
func devLaunchFrameWaitRespondsToBufferedWindowClose() async {
    let (stopRequests, stopContinuation) = AsyncStream.makeStream(of: Void.self)
    let (closeRequests, closeContinuation) = AsyncStream.makeStream(of: Void.self)
    closeContinuation.yield(())
    let signal = DevBootStopSignal()
    let monitor = DevBoot.observeStopRequests(
        stopRequests: stopRequests,
        appCloseRequests: closeRequests,
        signal: signal
    )
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    defer {
        monitor.cancel()
        stopContinuation.finish()
        closeContinuation.finish()
        display.finish()
    }

    let startedAt = ContinuousClock.now
    let result = await DevBoot.waitForFrame(after: 0, on: display, stopSignal: signal, timeout: .seconds(4))

    #expect(result == .stopped(.appWindowClosed))
    #expect(ContinuousClock.now - startedAt < .seconds(1))
}

@Test(.timeLimit(.minutes(1)))
func devBootInstallCloseDefersStopAndSkipsLaunchUntilInstallCompletes() async throws {
    let signal = DevBootStopSignal()
    let probe = DevBootStopProbe()
    await signal.attachStopHandler {
        await probe.record("stop")
    }
    let gate = DevBootInstallGate()

    let operation = Task {
        let mayLaunch = try await DevBoot.installAPKAndBeginLaunch(stopSignal: signal) {
            await probe.record("install-start")
            await gate.pause()
            await probe.record("install-finished")
        }
        if mayLaunch {
            await probe.record("launch")
        }
        return mayLaunch
    }

    await gate.waitUntilStarted()
    await signal.signal(.appWindowClosed)

    #expect(await signal.current() == .appWindowClosed)
    #expect(!(await signal.hasScheduledRuntimeStop()))
    #expect(await probe.events == ["install-start"])

    await gate.release()
    #expect(try await !operation.value)
    #expect(await probe.events == ["install-start", "install-finished"])
    #expect(!(await signal.hasScheduledRuntimeStop()))

    await signal.stopRuntime()
    #expect(await probe.events == ["install-start", "install-finished", "stop"])
}

@Test(.timeLimit(.minutes(1)))
func devBootStopSignalSkipsAPKInstallWhenWindowClosedFirst() async {
    let signal = DevBootStopSignal()
    let probe = DevBootStopProbe()
    await signal.attachStopHandler {
        await probe.record("stop")
    }

    await signal.signal(.appWindowClosed)

    #expect(!(await signal.beginPackageInstall()))
    #expect(await signal.hasScheduledRuntimeStop())
    await signal.stopRuntime()
    #expect(await probe.events == ["stop"])
}

@Test(.timeLimit(.minutes(1)))
func devBootStopSignalDefersStoppingUntilAnActiveDisplaySessionCanReleaseItsLease() async {
    let signal = DevBootStopSignal()
    let probe = DevBootStopProbe()
    await signal.attachStopHandler {
        await probe.record("stop")
    }
    #expect(await signal.beginDisplayAcquisition())

    await signal.signal(.signal)

    #expect(await signal.current() == .signal)
    #expect(!(await signal.hasScheduledRuntimeStop()))
    await signal.stopRuntime()
    #expect(await probe.events == ["stop"])
}

@Test func developerDisplayCountsOnlyNativeWindowFrameCommits() {
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    defer { display.finish() }

    #expect(display.statistics?.framesPresented == nil)
    #expect(display.windowFrameCommitCount == 0)

    display.frameDisplayed(sequence: 1)
    display.frameDisplayed(sequence: 2)

    #expect(display.windowFrameCommitCount == 2)
}

private actor DevBootStopProbe {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor DevBootInstallGate {
    private let started: AsyncStream<Void>
    private let startedContinuation: AsyncStream<Void>.Continuation
    private let releaseRequest: AsyncStream<Void>
    private let releaseContinuation: AsyncStream<Void>.Continuation

    init() {
        let (started, startedContinuation) = AsyncStream.makeStream(of: Void.self)
        self.started = started
        self.startedContinuation = startedContinuation
        let (releaseRequest, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        self.releaseRequest = releaseRequest
        self.releaseContinuation = releaseContinuation
    }

    func pause() async {
        startedContinuation.yield(())
        for await _ in releaseRequest {
            break
        }
    }

    func waitUntilStarted() async {
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releaseContinuation.yield(())
    }
}
