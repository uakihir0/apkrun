import CoreGraphics
import Testing

@testable import WindowingCore

// The geometry and the frame gate of display-and-windowing.md §5.3 and graphics.md §12 #023, without a window.

@Test func anAspectFitOfTheSameSizeFillsTheBounds() {
    let rect = DisplayGeometry.aspectFit(
        contentSize: CGSize(width: 1024, height: 768), in: CGSize(width: 1024, height: 768))
    #expect(rect == CGRect(x: 0, y: 0, width: 1024, height: 768))
}

@Test func aWiderWindowCentersTheContentWithSideBars() {
    let rect = DisplayGeometry.aspectFit(
        contentSize: CGSize(width: 1024, height: 768), in: CGSize(width: 2048, height: 768))
    #expect(rect == CGRect(x: 512, y: 0, width: 1024, height: 768))
}

@Test func aTallerWindowCentersTheContentWithBars() {
    let rect = DisplayGeometry.aspectFit(
        contentSize: CGSize(width: 1024, height: 768), in: CGSize(width: 1024, height: 1000))
    #expect(rect == CGRect(x: 0, y: 116, width: 1024, height: 768))
}

@Test func aSmallerWindowScalesTheContentDown() {
    let rect = DisplayGeometry.aspectFit(
        contentSize: CGSize(width: 1024, height: 768), in: CGSize(width: 512, height: 512))
    #expect(rect == CGRect(x: 0, y: 64, width: 512, height: 384))
}

@Test func anEmptySizeFitsNothing() {
    #expect(DisplayGeometry.aspectFit(contentSize: .zero, in: CGSize(width: 10, height: 10)) == .zero)
    #expect(DisplayGeometry.aspectFit(contentSize: CGSize(width: 10, height: 10), in: .zero) == .zero)
}

@Test func theContentSizeIsThePixelSizeAtTheBackingScale() {
    let size = DisplayGeometry.contentSize(pixelWidth: 1024, pixelHeight: 768, backingScale: 2)
    #expect(size == CGSize(width: 512, height: 384))
    #expect(
        DisplayGeometry.contentSize(pixelWidth: 1024, pixelHeight: 768, backingScale: 0)
            == CGSize(width: 1024, height: 768))
}

@Test func theGateShowsEachNewerFrameOfTheCurrentGeneration() {
    var gate = LayerFrameGate(generation: 1)
    let first = gate.accept(generation: 1, sequence: 1)
    let second = gate.accept(generation: 1, sequence: 2)
    #expect(first)
    #expect(second)
    #expect(gate.lastShownSequence == 2)
}

@Test func theGateDropsAReorderedOrRepeatedFrame() {
    var gate = LayerFrameGate(generation: 1)
    let initial = gate.accept(generation: 1, sequence: 5)
    let reordered = gate.accept(generation: 1, sequence: 4)
    let repeated = gate.accept(generation: 1, sequence: 5)
    #expect(initial)
    #expect(!reordered)
    #expect(!repeated)
    #expect(gate.lastShownSequence == 5)
}

@Test func theGateDropsFramesOfAnOlderGenerationAfterAChange() {
    var gate = LayerFrameGate(generation: 1)
    let before = gate.accept(generation: 1, sequence: 7)
    gate.switchTo(generation: 2)
    // Messages with the old generation are ignored on both sides (display-and-windowing.md §5.2, rule 6).
    let stale = gate.accept(generation: 1, sequence: 8)
    let current = gate.accept(generation: 2, sequence: 1)
    #expect(before)
    #expect(!stale)
    #expect(current)
    #expect(gate.generation == 2)
}

@Test func switchingToTheSameGenerationKeepsTheLastFrame() {
    var gate = LayerFrameGate(generation: 3)
    let shown = gate.accept(generation: 3, sequence: 4)
    gate.switchTo(generation: 3)
    let again = gate.accept(generation: 3, sequence: 4)
    #expect(shown)
    #expect(gate.lastShownSequence == 4)
    #expect(!again)
}
