import CoreGraphics
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
    let launching = try await service.beginLaunch()
    #expect(launching.state == .launching)

    let launched = try await service.launched(taskID: 19)
    #expect(launched.taskIDs == [19])
    let running = try await service.firstFramePresented()
    #expect(running.state == .running)

    let closing = try await service.windowClosed()
    #expect(closing.state == .closing)
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
    #expect(await guest.stoppedPackages == [package.rawValue, unmanaged.rawValue])
    display.finish()
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

private actor FakeEmbeddedSessionGuestAgent: EmbeddedSessionGuestAgent {
    private let installed: Bool
    private let stopResult: Bool
    private(set) var launchedPackages: [String] = []
    private(set) var stoppedPackages: [String] = []

    init(isInstalled: Bool = true, stopResult: Bool = true) {
        installed = isInstalled
        self.stopResult = stopResult
    }

    func isInstalled(_ package: String) async throws(GuestAgentFailure) -> Bool {
        installed
    }

    func launch(package: String, displayID: Int32) async throws(GuestAgentFailure) -> GuestLaunchReport {
        launchedPackages.append(package)
        return GuestLaunchReport(taskID: 23, component: "\(package)/.MainActivity", outcome: "started")
    }

    func stopApplication(package: String) async throws(GuestAgentFailure) -> Bool {
        stoppedPackages.append(package)
        return stopResult
    }
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

@Test func developerDisplayCountsOnlyNativeWindowFrameCommits() {
    let display = DeveloperDisplay(pixelWidth: 640, pixelHeight: 480)
    defer { display.finish() }

    #expect(display.statistics?.framesPresented == nil)
    #expect(display.windowFrameCommitCount == 0)

    display.frameDisplayed(sequence: 1)
    display.frameDisplayed(sequence: 2)

    #expect(display.windowFrameCommitCount == 2)
}
