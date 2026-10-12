import Testing

@testable import WindowingCore

// The tearing census of the test-only readback (graphics.md §12 #023, step 5). The pixels are BGRA8 bytes.

/// Builds a BGRA8 image of `width` x `height` pixels, with `rowBytes` bytes per row. `pixel(x, y)` gives (blue, green, red).
private func bgraImage(
    width: Int, height: Int, rowBytes: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)
) -> [UInt8] {
    var bytes = [UInt8](repeating: 0x7F, count: height * rowBytes)
    for y in 0..<height {
        for x in 0..<width {
            let (blue, green, red) = pixel(x, y)
            let offset = y * rowBytes + x * 4
            bytes[offset] = blue
            bytes[offset + 1] = green
            bytes[offset + 2] = red
            bytes[offset + 3] = 0xFF
        }
    }
    return bytes
}

private func census(_ bytes: [UInt8], width: Int, height: Int, rowBytes: Int, step: Int = 1) -> FrameColourCensus {
    bytes.withUnsafeBytes { raw in
        FrameColourCensus.census(of: raw.baseAddress!, width: width, height: height, bytesPerRow: rowBytes, step: step)
    }
}

@Test func aFrameOfPureRedHasRedPixelsOnly() {
    let bytes = bgraImage(width: 8, height: 4, rowBytes: 32) { _, _ in (0, 0, 255) }
    let result = census(bytes, width: 8, height: 4, rowBytes: 32)
    #expect(result == FrameColourCensus(sampled: 32, red: 32, blue: 0))
    #expect(!result.isMixed)
}

@Test func aFrameOfPureBlueHasBluePixelsOnly() {
    let bytes = bgraImage(width: 8, height: 4, rowBytes: 32) { _, _ in (255, 0, 0) }
    let result = census(bytes, width: 8, height: 4, rowBytes: 32)
    #expect(result == FrameColourCensus(sampled: 32, red: 0, blue: 32))
    #expect(!result.isMixed)
}

@Test func aFrameWithTopRedAndBottomBlueIsMixed() {
    let bytes = bgraImage(width: 8, height: 4, rowBytes: 32) { _, y in y < 2 ? (0, 0, 255) : (255, 0, 0) }
    let result = census(bytes, width: 8, height: 4, rowBytes: 32)
    #expect(result.red == 16)
    #expect(result.blue == 16)
    #expect(result.isMixed)
}

@Test func aGradientHasNeitherPureColour() {
    // The normal-mode clear of HelloGL has a green of 128, which is not one of the two colours.
    let bytes = bgraImage(width: 8, height: 4, rowBytes: 32) { x, _ in (UInt8(x * 30), 128, UInt8(255 - x * 30)) }
    let result = census(bytes, width: 8, height: 4, rowBytes: 32)
    #expect(result == FrameColourCensus(sampled: 32, red: 0, blue: 0))
}

@Test func paddingAtTheEndOfARowIsNotRead() {
    // Each row has 8 bytes of padding that are pure blue. The image itself is pure red.
    let bytes = bgraImage(width: 4, height: 3, rowBytes: 24) { _, _ in (0, 0, 255) }
    var padded = bytes
    for y in 0..<3 {
        for offset in 16..<24 {
            padded[y * 24 + offset] = offset % 4 == 0 ? 255 : 0
        }
    }
    let result = census(padded, width: 4, height: 3, rowBytes: 24)
    #expect(result == FrameColourCensus(sampled: 12, red: 12, blue: 0))
}

@Test func theStepSamplesEveryNthPixelInEachDirection() {
    let bytes = bgraImage(width: 8, height: 8, rowBytes: 32) { _, _ in (0, 0, 255) }
    let result = census(bytes, width: 8, height: 8, rowBytes: 32, step: 4)
    #expect(result == FrameColourCensus(sampled: 4, red: 4, blue: 0))
}

@Test func anEmptyImageSamplesNothing() {
    let bytes = [UInt8](repeating: 0, count: 4)
    #expect(census(bytes, width: 0, height: 0, rowBytes: 0) == FrameColourCensus(sampled: 0, red: 0, blue: 0))
}
