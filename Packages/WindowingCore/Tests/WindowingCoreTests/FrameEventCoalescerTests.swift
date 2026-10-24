import Testing

@testable import WindowingCore

@Test func frameCoalescerSchedulesOneMainQueueDeliveryForNewestFrame() {
    var coalescer = FrameEventCoalescer()

    #expect(coalescer.enqueue(.frameReady(generation: 1, bufferIndex: 0, sequence: 1)) == true)
    #expect(coalescer.enqueue(.frameReady(generation: 1, bufferIndex: 1, sequence: 2)) == false)
    #expect(coalescer.enqueue(.frameReady(generation: 1, bufferIndex: 2, sequence: 3)) == false)
    #expect(coalescer.takePending() == .frameReady(generation: 1, bufferIndex: 2, sequence: 3))

    #expect(coalescer.enqueue(.frameReady(generation: 1, bufferIndex: 1, sequence: 4)) == true)
    #expect(coalescer.takePending() == .frameReady(generation: 1, bufferIndex: 1, sequence: 4))
}

@Test func frameCoalescerDropsOlderGenerationAndSequence() {
    var coalescer = FrameEventCoalescer()

    let schedulesFrame = coalescer.enqueue(.frameReady(generation: 2, bufferIndex: 0, sequence: 8))
    #expect(schedulesFrame)
    #expect(coalescer.enqueue(.frameReady(generation: 2, bufferIndex: 1, sequence: 7)) == false)
    #expect(coalescer.enqueue(.surfacesReplaced(generation: 1)) == false)
    #expect(coalescer.enqueue(.frameReady(generation: 1, bufferIndex: 1, sequence: 9)) == false)
    #expect(coalescer.takePending() == .frameReady(generation: 2, bufferIndex: 0, sequence: 8))
}

@Test func frameCoalescerKeepsFrameSequenceMonotonicAcrossGenerations() {
    var coalescer = FrameEventCoalescer()

    let schedulesFirst = coalescer.enqueue(.frameReady(generation: 1, bufferIndex: 0, sequence: 8))
    #expect(schedulesFirst)
    #expect(coalescer.enqueue(.surfacesReplaced(generation: 2)) == false)
    #expect(coalescer.enqueue(.frameReady(generation: 2, bufferIndex: 1, sequence: 7)) == false)
    #expect(coalescer.takePending() == .surfacesReplaced(generation: 2))
}

@Test func frameCoalescerKeepsReplacementUntilItsFirstFrameArrives() {
    var coalescer = FrameEventCoalescer()

    let schedulesReplacement = coalescer.enqueue(.surfacesReplaced(generation: 2))
    #expect(schedulesReplacement)
    #expect(coalescer.takePending() == .surfacesReplaced(generation: 2))
    let schedulesFrame = coalescer.enqueue(.frameReady(generation: 2, bufferIndex: 0, sequence: 1))
    #expect(schedulesFrame)
    #expect(coalescer.takePending() == .frameReady(generation: 2, bufferIndex: 0, sequence: 1))
}

@Test func frameCoalescerLetsANewGenerationFrameReplaceAnUndeliveredMarker() {
    var coalescer = FrameEventCoalescer()

    let schedulesReplacement = coalescer.enqueue(.surfacesReplaced(generation: 2))
    #expect(schedulesReplacement)
    #expect(coalescer.enqueue(.frameReady(generation: 2, bufferIndex: 1, sequence: 1)) == false)
    #expect(coalescer.takePending() == .frameReady(generation: 2, bufferIndex: 1, sequence: 1))
}
