import Testing

@testable import GraphicsCore

// The buffer states of display-and-windowing.md §5.2 and the latest-frame policy of graphics.md §6.2, without a GPU.

@Test func aNewPoolHasFreeBuffersAndNothingOffered() {
    let states = PresentBufferStates(bufferCount: 3)
    #expect(states.count == 3)
    #expect(states.states == [.free, .free, .free])
    #expect(states.hasFreeBuffer)
}

@Test func acquireTakesTheFirstFreeBufferAndMarksItRendering() {
    var states = PresentBufferStates(bufferCount: 3)
    let first = states.acquire { _ in false }
    let second = states.acquire { _ in false }
    #expect(first == 0)
    #expect(second == 1)
    #expect(states.states == [.rendering, .rendering, .free])
}

@Test func acquireSkipsABufferThatWindowServerStillReads() {
    var states = PresentBufferStates(bufferCount: 3)
    // Rule 2b: buffer 0 is still in use, so it stays free and buffer 1 is taken.
    let taken = states.acquire { $0 == 0 }
    #expect(taken == 1)
    #expect(states.states == [.free, .rendering, .free])
}

@Test func acquireReturnsNilWhenEveryBufferIsBusy() {
    var states = PresentBufferStates(bufferCount: 2)
    _ = states.acquire { _ in false }
    _ = states.acquire { _ in false }
    let none = states.acquire { _ in false }
    #expect(none == nil)
    #expect(!states.hasFreeBuffer)
}

@Test func onlyARenderingBufferBecomesOffered() {
    var states = PresentBufferStates(bufferCount: 2)
    // A free buffer cannot be offered (rule 1: only a rendered frame is offered).
    let beforeAcquire = states.markReady(0, sequence: 1)
    #expect(!beforeAcquire)
    _ = states.acquire { _ in false }
    let offered = states.markReady(0, sequence: 1)
    #expect(offered)
    #expect(states.states == [.offered(sequence: 1), .free])
    // A second offer of the same buffer is refused.
    let twice = states.markReady(0, sequence: 2)
    #expect(!twice)
}

@Test func aFailedBlitReturnsItsBufferToFreeWithoutAnOffer() {
    var states = PresentBufferStates(bufferCount: 2)
    _ = states.acquire { _ in false }
    let abandoned = states.abandon(0)
    #expect(abandoned)
    #expect(states.states == [.free, .free])
    let again = states.abandon(0)
    #expect(!again)
}

@Test func theConsumerReleasesOlderBuffersAndDisplaysTheNewestOffer() {
    var states = PresentBufferStates(bufferCount: 3)
    for sequence in UInt64(1)...3 {
        let index = states.acquire { _ in false }!
        states.markReady(index, sequence: sequence)
    }
    // Frames 1, 2, and 3 are offered. The consumer reports frame 2 as displayed.
    let released = states.consumerDisplayed(upTo: 2)
    #expect(released == 1)
    #expect(states.states == [.free, .displayed(sequence: 2), .offered(sequence: 3)])
}

@Test func aSteadyStateKeepsOneDisplayedAndOneOfferedAndRendersInTheRest() {
    var states = PresentBufferStates(bufferCount: 3)
    var sequence: UInt64 = 0
    for _ in 0..<6 {
        sequence += 1
        let index = states.acquire { _ in false }!
        states.markReady(index, sequence: sequence)
        // The consumer displays each frame as soon as it is offered.
        states.consumerDisplayed(upTo: sequence)
    }
    let displayed = states.states.filter { if case .displayed = $0 { true } else { false } }
    #expect(displayed.count == 1)
    #expect(states.states.filter { $0 == .free }.count == 2)
}

@Test func aReportForAnOlderFrameChangesNothing() {
    var states = PresentBufferStates(bufferCount: 2)
    _ = states.acquire { _ in false }
    states.markReady(0, sequence: 2)
    states.consumerDisplayed(upTo: 2)
    let before = states
    let released = states.consumerDisplayed(upTo: 1)
    #expect(released == 0)
    #expect(states == before)
}

@Test func aSchedulerRunsTheFirstRequestAndHoldsTheRestWhileABlitIsInFlight() {
    var scheduler = LatestFrameScheduler<Int>()
    let first = scheduler.submit(1)
    #expect(first == 1)
    scheduler.beginBlit()
    let second = scheduler.submit(2)
    #expect(second == nil)
    #expect(scheduler.pending == 2)
    let third = scheduler.submit(3)
    #expect(third == nil)
    // The newest request replaces the held one, and the replaced frame counts as dropped.
    #expect(scheduler.pending == 3)
    #expect(scheduler.droppedFrames == 1)
    scheduler.endBlit()
    let held = scheduler.takePending()
    #expect(held == 3)
    #expect(scheduler.pending == nil)
}

@Test func aHeldRequestWaitsForTheInFlightBlitToEnd() {
    var scheduler = LatestFrameScheduler<String>()
    scheduler.beginBlit()
    scheduler.hold("frame")
    let early = scheduler.takePending()
    #expect(early == nil)
    #expect(scheduler.pending == "frame")
    scheduler.endBlit()
    let late = scheduler.takePending()
    #expect(late == "frame")
}

@Test func holdingWithoutAReplacementDoesNotCountADrop() {
    var scheduler = LatestFrameScheduler<Int>()
    scheduler.hold(7)
    #expect(scheduler.droppedFrames == 0)
    scheduler.hold(8)
    #expect(scheduler.droppedFrames == 1)
}

@Test func discardingThePendingRequestForgetsItWithoutCountingADrop() {
    var scheduler = LatestFrameScheduler<Int>()
    scheduler.beginBlit()
    scheduler.hold(4)
    scheduler.discardPending()
    #expect(scheduler.pending == nil)
    #expect(scheduler.droppedFrames == 0)
}
