import CoreGraphics
import InputCore
import Testing

@testable import WindowingCore

// The mapper that the pointer view builds from its content rectangle (input.md §3, #25), without a window.

@Test func aSteadyStateMapperMapsTheWholeContentToThePixels() {
    let mapper = DisplayGeometry.coordinateMapper(
        contentSize: CGSize(width: 512, height: 384), in: CGSize(width: 512, height: 384),
        pixelWidth: 1024, pixelHeight: 768, generation: 1)
    // The window's bottom-left corner is the display's bottom-left pixel (AppKit y up, Android y down).
    // The far edges map to the last pixel, because the guest rejects x = 1024 and y = 768.
    #expect(mapper.map(windowX: 0, windowY: 0) == DisplayPoint(x: 0, y: 767))
    #expect(mapper.map(windowX: 512, windowY: 384) == DisplayPoint(x: 1023, y: 0))
    #expect(mapper.map(windowX: 256, windowY: 192) == DisplayPoint(x: 512, y: 384))
}

@Test func aPointInTheLetterboxMapsToNothingAndAClampedPointStaysOnTheEdge() {
    // A 600 x 384 window shows the 512 x 384 content centred, so the content starts 44 points from the left edge.
    let mapper = DisplayGeometry.coordinateMapper(
        contentSize: CGSize(width: 512, height: 384), in: CGSize(width: 600, height: 384),
        pixelWidth: 1024, pixelHeight: 768, generation: 1)
    #expect(mapper.map(windowX: 10, windowY: 100) == nil)
    #expect(mapper.map(windowX: 44 + 256, windowY: 192) == DisplayPoint(x: 512, y: 384))
    #expect(mapper.clamped(windowX: 0, windowY: 1000) == DisplayPoint(x: 0, y: 0))
    #expect(mapper.clamped(windowX: 1000, windowY: -5) == DisplayPoint(x: 1023, y: 767))
}

@Test func theMapperKeepsItsGeneration() {
    let mapper = DisplayGeometry.coordinateMapper(
        contentSize: CGSize(width: 512, height: 384), in: CGSize(width: 512, height: 384),
        pixelWidth: 1024, pixelHeight: 768, generation: 7)
    #expect(mapper.generation == 7)
    #expect(mapper.isUsable)
}

@Test func aMapperForAnEmptyWindowMapsNothing() {
    let mapper = DisplayGeometry.coordinateMapper(
        contentSize: CGSize(width: 512, height: 384), in: .zero,
        pixelWidth: 1024, pixelHeight: 768, generation: 1)
    #expect(!mapper.isUsable)
    #expect(mapper.map(windowX: 0, windowY: 0) == nil)
}
