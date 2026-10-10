import Foundation
import Testing
import VirtualMachineCore

@testable import RuntimeCore

/// A VM for the stop sequence. A power-off request starts a shutdown that finishes `powerOffDelay` later, or never
/// finishes when the delay is nil. A forced stop always stops the VM.
private actor FakeAndroidVM {
    private(set) var state: VMState = .running
    private(set) var requestCount = 0
    private(set) var forceCount = 0
    private(set) var forcedAt: ContinuousClock.Instant?
    private var requestedAt: ContinuousClock.Instant?
    private let powerOffDelay: Duration?

    init(powerOffDelay: Duration?) {
        self.powerOffDelay = powerOffDelay
    }

    func requestPowerOff() -> Bool {
        requestCount += 1
        requestedAt = ContinuousClock.now
        return true
    }

    func isStopped() -> Bool {
        if let powerOffDelay, let requestedAt, ContinuousClock.now >= requestedAt + powerOffDelay {
            state = .stopped
        }
        return state == .stopped
    }

    func forceStop() {
        forceCount += 1
        forcedAt = ContinuousClock.now
        state = .stopped
    }
}

/// Android that never finishes the graceful stop gets the forced stop after the deadline, and the VM ends stopped.
@Test(.timeLimit(.minutes(1)))
func aForcedStopFollowsTheDeadlineWhenAndroidNeverPowersOff() async throws {
    let deadline = Duration.milliseconds(300)
    let vm = FakeAndroidVM(powerOffDelay: nil)
    let started = ContinuousClock.now

    await AndroidStopSequence(deadline: deadline).run(
        requestPowerOff: { await vm.requestPowerOff() },
        isStopped: { await vm.isStopped() },
        forceStop: { await vm.forceStop() }
    )

    #expect(await vm.requestCount == 1)
    #expect(await vm.forceCount == 1)
    let forcedAt = try #require(await vm.forcedAt)
    #expect(forcedAt - started >= deadline)
    #expect(forcedAt - started < deadline + .seconds(5))
    #expect(await vm.state == .stopped)
}

/// Cancelling the stop task does not shorten the deadline: the VM still has to stop, so the forced stop comes after the
/// deadline all the same.
@Test(.timeLimit(.minutes(1)))
func aCancelledStopStillWaitsOutTheDeadline() async throws {
    let deadline = Duration.milliseconds(600)
    let vm = FakeAndroidVM(powerOffDelay: nil)
    let started = ContinuousClock.now

    let stop = Task {
        await AndroidStopSequence(deadline: deadline).run(
            requestPowerOff: { await vm.requestPowerOff() },
            isStopped: { await vm.isStopped() },
            forceStop: { await vm.forceStop() }
        )
    }
    try await Task.sleep(for: .milliseconds(100))
    stop.cancel()
    await stop.value

    #expect(await vm.forceCount == 1)
    let forcedAt = try #require(await vm.forcedAt)
    #expect(forcedAt - started >= deadline)
    #expect(await vm.state == .stopped)
}

/// A graceful stop that finishes inside the deadline ends the wait, and no forced stop is made.
@Test(.timeLimit(.minutes(1)))
func aGracefulStopThatFinishesInTimeIsNotForced() async {
    let deadline = Duration.seconds(5)
    let vm = FakeAndroidVM(powerOffDelay: .milliseconds(200))
    let started = ContinuousClock.now

    await AndroidStopSequence(deadline: deadline).run(
        requestPowerOff: { await vm.requestPowerOff() },
        isStopped: { await vm.isStopped() },
        forceStop: { await vm.forceStop() }
    )

    #expect(await vm.requestCount == 1)
    #expect(await vm.forceCount == 0)
    #expect(await vm.state == .stopped)
    #expect(ContinuousClock.now - started < deadline)
}

/// Outside developer mode there is no power-off request, so the VM is stopped at once and nothing waits.
@Test(.timeLimit(.minutes(1)))
func aStopWithoutARequestForcesAtOnce() async {
    let vm = FakeAndroidVM(powerOffDelay: nil)
    let started = ContinuousClock.now

    await AndroidStopSequence(deadline: .seconds(5)).run(
        requestPowerOff: nil,
        isStopped: { await vm.isStopped() },
        forceStop: { await vm.forceStop() }
    )

    #expect(await vm.requestCount == 0)
    #expect(await vm.forceCount == 1)
    #expect(ContinuousClock.now - started < .seconds(5))
}

/// A request that no channel sent leaves nothing to wait for, so the VM is stopped at once.
@Test(.timeLimit(.minutes(1)))
func aPowerOffThatWasNotSentForcesAtOnce() async {
    let vm = FakeAndroidVM(powerOffDelay: nil)
    let started = ContinuousClock.now

    await AndroidStopSequence(deadline: .seconds(5)).run(
        requestPowerOff: { false },
        isStopped: { await vm.isStopped() },
        forceStop: { await vm.forceStop() }
    )

    #expect(await vm.forceCount == 1)
    #expect(ContinuousClock.now - started < .seconds(5))
}

/// The production deadline is the 20 s of vm.md §9.3, and a sequence made without a deadline uses it.
@Test
func theStandardStopDeadlineIsTwentySeconds() {
    #expect(AndroidStopSequence.standardDeadline == .seconds(20))
    #expect(AndroidStopSequence().deadline == .seconds(20))
}

/// Records the power-off channels that were tried, in order.
private actor ChannelRecorder {
    private(set) var calls: [String] = []

    func attempt(_ channel: String, succeeds: Bool) -> Bool {
        calls.append(channel)
        return succeeds
    }
}

/// A power-off that ADB accepts is the whole request, and the serial shell is not tried.
@Test
func aPowerOffAcceptedByADBIsNotSentAgainOverTheShell() async {
    let recorder = ChannelRecorder()
    let tried = await AndroidStopSequence.sendPowerOff(
        overADB: { await recorder.attempt("adb", succeeds: true) },
        overShell: { await recorder.attempt("shell", succeeds: true) }
    )
    #expect(tried)
    #expect(await recorder.calls == ["adb"])
}

/// A failed ADB request is retried over the serial shell.
@Test
func aFailedADBRequestFallsBackToTheShell() async {
    let recorder = ChannelRecorder()
    let tried = await AndroidStopSequence.sendPowerOff(
        overADB: { await recorder.attempt("adb", succeeds: false) },
        overShell: { await recorder.attempt("shell", succeeds: true) }
    )
    #expect(tried)
    #expect(await recorder.calls == ["adb", "shell"])
}

/// A failed ADB request with no serial shell still counts as tried. The reply may have been lost after Android
/// received the request, so the stop waits for the deadline instead of forcing at once.
@Test
func aFailedADBRequestWithoutAShellStillCountsAsTried() async {
    let recorder = ChannelRecorder()
    let tried = await AndroidStopSequence.sendPowerOff(
        overADB: { await recorder.attempt("adb", succeeds: false) },
        overShell: nil
    )
    #expect(tried)
    #expect(await recorder.calls == ["adb"])
}

/// A request that failed on every channel was still tried.
@Test
func aRequestThatFailedOnEveryChannelStillCountsAsTried() async {
    let recorder = ChannelRecorder()
    let tried = await AndroidStopSequence.sendPowerOff(
        overADB: { await recorder.attempt("adb", succeeds: false) },
        overShell: { await recorder.attempt("shell", succeeds: false) }
    )
    #expect(tried)
    #expect(await recorder.calls == ["adb", "shell"])
}

/// With neither channel there is nothing to send, so the request is not tried and the stop does not wait.
@Test
func aPowerOffWithNoChannelIsNotTried() async {
    let tried = await AndroidStopSequence.sendPowerOff(overADB: nil, overShell: nil)
    #expect(!tried)
}
