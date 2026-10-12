import Testing

@testable import InputCore

// The reference vectors of scripts/dev/validate-input-coordinates.sh (--self-test). The two must agree.

private let fullContent = DisplayRect(x: 0, y: 0, width: 512, height: 384)
private let insetContent = DisplayRect(x: 40, y: 30, width: 400, height: 300)

private func makeMapper(
    _ content: DisplayRect, pixelWidth: Int = 1024, pixelHeight: Int = 768, generation: UInt64 = 1
) -> CoordinateMapper {
    CoordinateMapper(
        contentRect: content, pixelWidth: pixelWidth, pixelHeight: pixelHeight, generation: generation)
}

@Test func theReferenceVectorsOfTheFullContentMap() {
    let mapper = makeMapper(fullContent)
    let vectors: [(wx: Double, wy: Double, px: Double, py: Double)] = [
        (0, 384, 0, 0),
        (512, 0, 1023, 767),
        (256, 192, 512, 384),
        (100, 300, 200, 168),
        (100.5, 300.25, 201, 167.5),
        (0, 0, 0, 767),
    ]
    for vector in vectors {
        #expect(
            mapper.map(windowX: vector.wx, windowY: vector.wy) == DisplayPoint(x: vector.px, y: vector.py),
            "window (\(vector.wx), \(vector.wy))")
    }
}

@Test func theReferenceVectorsOfTheInsetContentMap() {
    let mapper = makeMapper(insetContent)
    let vectors: [(wx: Double, wy: Double, px: Double, py: Double)] = [
        (40, 330, 0, 0),
        (440, 30, 1023, 767),
        (240, 180, 512, 384),
    ]
    for vector in vectors {
        #expect(
            mapper.map(windowX: vector.wx, windowY: vector.wy) == DisplayPoint(x: vector.px, y: vector.py),
            "window (\(vector.wx), \(vector.wy))")
    }
}

@Test func theContentEdgesAreInsideTheContent() {
    let mapper = makeMapper(insetContent)
    #expect(mapper.map(windowX: 40, windowY: 30) == DisplayPoint(x: 0, y: 767))
    #expect(mapper.map(windowX: 440, windowY: 330) == DisplayPoint(x: 1023, y: 0))
}

@Test func theFarEdgesMapToTheLastPixelAndNeverPastIt() {
    // The guest rejects x >= width and y >= height (InputService.inside), so no mapped point may reach W or H.
    for content in [fullContent, insetContent] {
        let mapper = makeMapper(content)
        for step in 0...20 {
            let x = content.x + content.width * Double(step) / 20
            for row in 0...10 {
                let y = content.y + content.height * Double(row) / 10
                guard let pixel = mapper.map(windowX: x, windowY: y) else {
                    Issue.record("the content edge (\(x), \(y)) is not mapped")
                    continue
                }
                #expect(pixel.x >= 0 && pixel.x <= 1023, "window (\(x), \(y))")
                #expect(pixel.y >= 0 && pixel.y <= 767, "window (\(x), \(y))")
            }
        }
    }
}

@Test func aPointInTheLetterboxIsNotMapped() {
    let mapper = makeMapper(insetContent)
    // The window point (10, 180) of the inset reference vector lies left of the content.
    #expect(mapper.map(windowX: 10, windowY: 180) == nil)
    #expect(mapper.map(windowX: 450, windowY: 100) == nil)
    #expect(mapper.map(windowX: 100, windowY: 20) == nil)
    #expect(mapper.map(windowX: 100, windowY: 340) == nil)
}

@Test func aNonFinitePointIsNotMapped() {
    let mapper = makeMapper(fullContent)
    #expect(mapper.map(windowX: .nan, windowY: 100) == nil)
    #expect(mapper.map(windowX: 100, windowY: .infinity) == nil)
}

@Test func aPointOutsideTheContentIsClampedToTheEdge() {
    let mapper = makeMapper(insetContent)
    // The inset reference vector (10, 180): x is clamped to 40, which is pixel 0, and y stays at 384.
    #expect(mapper.clamped(windowX: 10, windowY: 180) == DisplayPoint(x: 0, y: 384))
    // (600, 100): x is clamped to 440, which is the last pixel column 1023; y = (330 - 100) * 768 / 300.
    #expect(mapper.clamped(windowX: 600, windowY: 100) == DisplayPoint(x: 1023, y: 588.8))
    // (600, -50): y is clamped to 30, which is the last pixel row 767.
    #expect(mapper.clamped(windowX: 600, windowY: -50) == DisplayPoint(x: 1023, y: 767))
}

@Test func aPointInsideTheContentIsClampedToItsMapping() {
    let mapper = makeMapper(fullContent)
    #expect(mapper.clamped(windowX: 100, windowY: 300) == mapper.map(windowX: 100, windowY: 300))
}

@Test func theInverseGivesTheWindowPointOfAPixel() {
    let mapper = makeMapper(fullContent)
    let point = mapper.windowPoint(forPixel: DisplayPoint(x: 200, y: 168))
    #expect(point.x == 100)
    #expect(point.y == 300)
}

@Test func theCornersOfTheDisplayAreTheCornersOfTheContent() {
    let mapper = makeMapper(fullContent)
    let top = mapper.windowPoint(forPixel: DisplayPoint(x: 0, y: 0))
    let bottomRight = mapper.windowPoint(forPixel: DisplayPoint(x: 1024, y: 768))
    let bottomLeft = mapper.windowPoint(forPixel: DisplayPoint(x: 0, y: 768))
    #expect(top == (x: 0, y: 384))
    #expect(bottomRight == (x: 512, y: 0))
    #expect(bottomLeft == (x: 0, y: 0))
}

@Test func mappingAndItsInverseRoundTrip() {
    for content in [fullContent, insetContent] {
        let mapper = makeMapper(content)
        // A point inside the far edges round-trips exactly. A point on the far edge (maxX, minY) is clamped to the last
        // pixel, so its inverse is where that pixel begins: one pixel in from the edge.
        let pixelWidthInPoints = content.width / 1024
        let pixelHeightInPoints = content.height / 768
        for step in 0...20 {
            let x = content.x + content.width * Double(step) / 20
            for row in 0...10 {
                let y = content.y + content.height * Double(row) / 10
                guard let pixel = mapper.map(windowX: x, windowY: y) else {
                    Issue.record("the content edge (\(x), \(y)) is not mapped")
                    continue
                }
                let back = mapper.windowPoint(forPixel: pixel)
                let slackX = step == 20 ? pixelWidthInPoints : 0
                let slackY = row == 0 ? pixelHeightInPoints : 0
                #expect(abs(back.x - x) <= slackX + 1e-9)
                #expect(abs(back.y - y) <= slackY + 1e-9)
            }
        }
    }
}

@Test func aNewGenerationWithANewPixelSizeMapsToTheNewPixels() {
    let old = makeMapper(fullContent, generation: 1)
    let new = makeMapper(fullContent, pixelWidth: 2048, pixelHeight: 1536, generation: 2)
    #expect(old != new)
    #expect(new.generation == 2)
    #expect(old.map(windowX: 256, windowY: 192) == DisplayPoint(x: 512, y: 384))
    #expect(new.map(windowX: 256, windowY: 192) == DisplayPoint(x: 1024, y: 768))
}

@Test func anEmptyOrNegativeMapperMapsNothing() {
    let degenerate: [CoordinateMapper] = [
        makeMapper(DisplayRect(x: 0, y: 0, width: 0, height: 384)),
        makeMapper(DisplayRect(x: 0, y: 0, width: 512, height: -1)),
        makeMapper(fullContent, pixelWidth: 0),
        makeMapper(fullContent, pixelHeight: -768),
        makeMapper(DisplayRect(x: .nan, y: 0, width: 512, height: 384)),
    ]
    for mapper in degenerate {
        #expect(!mapper.isUsable)
        #expect(mapper.map(windowX: 10, windowY: 10) == nil)
        #expect(mapper.clamped(windowX: 10, windowY: 10) == DisplayPoint(x: 0, y: 0))
    }
}
