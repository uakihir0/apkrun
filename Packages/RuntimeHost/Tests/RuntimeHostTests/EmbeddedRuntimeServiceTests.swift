import RuntimeCore
import Testing

@testable import RuntimeHost

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
