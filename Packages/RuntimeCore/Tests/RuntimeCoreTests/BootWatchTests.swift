import DiagnosticsCore
import Foundation
import Testing
import VirtualMachineCore

@testable import RuntimeCore

/// The readiness timeouts and stall limit of runtime-daemon.md §3.2, with a test clock.
@Test
func bootWatchCompletesAtBootCompletedAndIgnoresLaterInput() {
    let origin = ContinuousClock.now
    var watch = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    #expect(watch.receive(.entered(.kernel), at: origin + .seconds(1)) == .keepWaiting)
    #expect(watch.receive(.entered(.`init`), at: origin + .seconds(2)) == .keepWaiting)
    #expect(watch.receive(.entered(.systemServer), at: origin + .seconds(3)) == .keepWaiting)
    #expect(watch.receive(.entered(.bootCompleted), at: origin + .seconds(12)) == .bootCompleted)
    #expect(watch.phase == .bootCompleted)
}

@Test
func bootWatchTimesOutTheWholeBootWithTheCurrentPhase() {
    let origin = ContinuousClock.now
    var watch = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    // Progress every 60 s keeps the stall limit away, so only the whole-boot limit fires.
    #expect(watch.receive(.entered(.`init`), at: origin + .seconds(60)) == .keepWaiting)
    #expect(watch.receive(.entered(.systemServer), at: origin + .seconds(120)) == .keepWaiting)
    #expect(watch.receive(.tick, at: origin + .seconds(180)) == .keepWaiting)
    #expect(watch.receive(.tick, at: origin + .seconds(181)) == .fail(.bootTimedOut(phase: .systemServer)))
}

@Test
func bootWatchStallsWhenNoPhaseArrivesWithinTheLimit() {
    let origin = ContinuousClock.now
    var watch = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    #expect(watch.receive(.entered(.`init`), at: origin + .seconds(10)) == .keepWaiting)
    // Exactly at the limit is not a stall; one tick later it is.
    #expect(watch.receive(.tick, at: origin + .seconds(100)) == .keepWaiting)
    #expect(watch.receive(.tick, at: origin + .seconds(101)) == .fail(.bootStalled(phase: .`init`)))
}

@Test
func bootWatchReportsTheTimeoutBeforeTheStallWhenBothHaveElapsed() {
    let origin = ContinuousClock.now
    var watch = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    // No progress at all: at 200 s both limits have passed, and the whole-boot limit is reported.
    #expect(watch.receive(.tick, at: origin + .seconds(200)) == .fail(.bootTimedOut(phase: .kernel)))
}

@Test
func bootWatchUsesTheFirstBootLimitsWhenTheCallerPassesThem() {
    let origin = ContinuousClock.now
    var watch = BootWatch(started: origin, whole: .seconds(900), stall: .seconds(600))
    #expect(watch.receive(.entered(.kernel), at: origin + .seconds(300)) == .keepWaiting)
    #expect(watch.receive(.tick, at: origin + .seconds(601)) == .keepWaiting)
    #expect(watch.receive(.tick, at: origin + .seconds(901)) == .fail(.bootTimedOut(phase: .kernel)))
}

@Test
func bootWatchFailsAtOnceOnDetectorAndVMFailures() {
    let origin = ContinuousClock.now
    var panic = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    #expect(panic.receive(.detectorFailed(.kernelPanic), at: origin) == .fail(.kernelPanic))

    var vm = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    #expect(vm.receive(.vmFailed(.stopTimedOut), at: origin) == .fail(.vm(.stopTimedOut)))
}

@Test
func bootWatchReportsAGuestStopOnlyAfterTheFirstMillisecond() {
    let origin = ContinuousClock.now
    var immediate = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    #expect(immediate.receive(.guestStopped, at: origin) == .keepWaiting)

    var later = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    #expect(
        later.receive(.guestStopped, at: origin + .seconds(2))
            == .fail(.androidBootFailed(detail: "the guest stopped while booting"))
    )
}

@Test
func bootWatchStopsWhenStopIsRequested() {
    let origin = ContinuousClock.now
    var watch = BootWatch(started: origin, whole: .seconds(180), stall: .seconds(90))
    #expect(
        watch.receive(.stopRequested, at: origin + .seconds(1))
            == .fail(.androidBootFailed(detail: "the runtime was stopped during boot"))
    )
}
