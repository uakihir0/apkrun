/// Builds the 128-byte EDID 1.4 base block of one scanout (graphics.md §6.4).
///
/// The block has the manufacturer `APK`, the scanout index as product code and
/// serial, one CVT reduced-blanking detailed timing for the scanout's mode, range
/// limits, and the name `APKRun <index>`. The output is deterministic, so the
/// golden files in `Tests/Fixtures/graphics/edid/` pin it.
enum EDIDGenerator {
    /// The size of the base block.
    static let byteCount = VirtioGPUProtocol.edidByteCount

    /// The EDID model year written in the header: 36 is 2026, counted from 1990.
    static let modelYearOffset: UInt8 = 36

    /// Returns the base block for `mode` on `scanout`.
    ///
    /// Throws `GraphicsFailure.modeUnsupported` when the mode is outside the
    /// EDID limits: a size over 4095 pixels, a density that gives a size over
    /// 4095 mm, a pixel clock that the 16-bit descriptor cannot hold, or a horizontal
    /// frequency outside the range limits descriptor.
    static func make(scanout: ScanoutID, mode: DisplayMode) throws(GraphicsFailure) -> [UInt8] {
        guard mode.isSupported else {
            throw .modeUnsupported(mode: mode)
        }
        let widthMM = millimeters(pixels: mode.widthPixels, dotsPerInch: mode.dotsPerInch)
        let heightMM = millimeters(pixels: mode.heightPixels, dotsPerInch: mode.dotsPerInch)
        guard widthMM <= 4095, heightMM <= 4095 else {
            throw .modeUnsupported(mode: mode)
        }
        let timing = try reducedBlankingTiming(for: mode, widthMM: widthMM, heightMM: heightMM)

        var edid = [UInt8](repeating: 0, count: byteCount)
        // Header, manufacturer ID "APK", and product code.
        edid.replaceSubrange(0..<8, with: [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
        let manufacturer = manufacturerIDBytes("APK")
        edid[8] = manufacturer.0
        edid[9] = manufacturer.1
        littleEndian(UInt32(scanout.rawValue), into: &edid, at: 10, byteCount: 2)
        littleEndian(UInt32(scanout.rawValue), into: &edid, at: 12, byteCount: 4)
        edid[16] = 0x00  // week not specified
        edid[17] = modelYearOffset
        edid[18] = 0x01  // EDID version 1
        edid[19] = 0x04  // EDID revision 4
        edid[20] = 0xA0  // digital input, 8 bits per color, interface not defined
        edid[21] = centimeters(millimeters: widthMM)
        edid[22] = centimeters(millimeters: heightMM)
        edid[23] = 0x78  // gamma 2.2 (value * 100 - 100)
        edid[24] = 0x0E  // RGB 4:4:4, sRGB default color space, preferred timing in the first descriptor
        edid.replaceSubrange(25..<35, with: srgbChromaticityBytes())
        // Established timings (35...37) stay zero. Standard timings (38...53) are unused: 0x01 0x01 pairs.
        edid.replaceSubrange(35..<38, with: [0x00, 0x00, 0x00])
        edid.replaceSubrange(38..<54, with: Array(repeating: 0x01, count: 16))
        edid.replaceSubrange(54..<72, with: detailedTimingBytes(timing))
        edid.replaceSubrange(72..<90, with: rangeLimitBytes())
        edid.replaceSubrange(90..<108, with: textDescriptorBytes(tag: 0xFC, text: "APKRun \(scanout.rawValue)"))
        edid.replaceSubrange(108..<126, with: dummyDescriptorBytes())
        edid[126] = 0  // no extension blocks
        edid[127] = checksum(of: edid.prefix(127))
        return edid
    }

    /// Whether the reduced-blanking timing of `mode` fits the detailed timing field and the
    /// horizontal frequency range that `rangeLimitBytes` advertises.
    static func expresses(_ mode: DisplayMode) -> Bool {
        guard let timing = try? reducedBlankingTiming(for: mode, widthMM: 0, heightMM: 0) else {
            return false
        }
        let horizontalTotal = timing.hActive + timing.hBlank
        let horizontalHertz = timing.pixelClock10kHz * 10_000 / horizontalTotal
        let rangeHertz = (horizontalRangeKHz.lowerBound * 1_000)...(horizontalRangeKHz.upperBound * 1_000)
        return rangeHertz.contains(horizontalHertz)
    }

    /// The CVT reduced-blanking timing of one mode, in pixels, lines, and clock units.
    struct Timing: Equatable {
        var pixelClock10kHz: Int
        var hActive: Int
        var hBlank: Int
        var hFront: Int
        var hSync: Int
        var vActive: Int
        var vBlank: Int
        var vFront: Int
        var vSync: Int
        var widthMM: Int
        var heightMM: Int
    }

    // Reduced blanking constants of CVT 1.2 (graphics.md §6.4 names the rule, not the constants).
    private static let reducedHorizontalBlank = 160
    private static let reducedHorizontalFront = 48
    private static let reducedHorizontalSync = 32
    private static let reducedVerticalFront = 3
    private static let reducedVerticalSync = 8
    private static let reducedMinimumVerticalBack = 6
    private static let reducedMinimumVerticalBlankMicroseconds = 460.0
    /// The pixel clock steps down to 250 kHz, which is 25 units of 10 kHz.
    private static let pixelClockStep10kHz = 25
    /// The horizontal frequency range in the range limits descriptor, in kHz.
    private static let horizontalRangeKHz = 30...255

    static func reducedBlankingTiming(
        for mode: DisplayMode,
        widthMM: Int,
        heightMM: Int
    ) throws(GraphicsFailure) -> Timing {
        let verticalMinimum = reducedVerticalFront + reducedVerticalSync + reducedMinimumVerticalBack
        let horizontalPeriodEstimate =
            (1_000_000.0 / Double(mode.refreshHz) - reducedMinimumVerticalBlankMicroseconds)
            / Double(mode.heightPixels)
        let blankLines = Int(reducedMinimumVerticalBlankMicroseconds / horizontalPeriodEstimate) + 1
        let vBlank = max(blankLines, verticalMinimum)
        let hTotal = mode.widthPixels + reducedHorizontalBlank
        let vTotal = mode.heightPixels + vBlank
        let hertz = hTotal * vTotal * mode.refreshHz
        let steps = hertz / 250_000
        let pixelClock10kHz = steps * pixelClockStep10kHz
        // The detailed timing holds the clock in 16 bits of 10 kHz units.
        guard pixelClock10kHz >= 1, pixelClock10kHz <= Int(UInt16.max) else {
            throw .modeUnsupported(mode: mode)
        }
        return Timing(
            pixelClock10kHz: pixelClock10kHz,
            hActive: mode.widthPixels,
            hBlank: reducedHorizontalBlank,
            hFront: reducedHorizontalFront,
            hSync: reducedHorizontalSync,
            vActive: mode.heightPixels,
            vBlank: vBlank,
            vFront: reducedVerticalFront,
            vSync: reducedVerticalSync,
            widthMM: widthMM,
            heightMM: heightMM
        )
    }

    /// Converts pixels at a density to millimeters, rounded to the nearest millimeter.
    static func millimeters(pixels: Int, dotsPerInch: Int) -> Int {
        Int((Double(pixels) * 25.4 / Double(dotsPerInch)).rounded())
    }

    /// The base block's image size is in centimeters. Sizes it cannot hold are 0 (unknown).
    static func centimeters(millimeters: Int) -> UInt8 {
        let centimeters = Int((Double(millimeters) / 10).rounded())
        return centimeters <= 255 ? UInt8(centimeters) : 0
    }

    /// Packs three uppercase letters into the 2-byte big-endian manufacturer ID.
    private static func manufacturerIDBytes(_ letters: String) -> (UInt8, UInt8) {
        let values = letters.utf8.map { UInt16($0 - 0x40) }
        let packed = (values[0] << 10) | (values[1] << 5) | values[2]
        return (UInt8(packed >> 8), UInt8(packed & 0xFF))
    }

    /// The 10-bit sRGB chromaticity coordinates, split as EDID 1.4 Table 3.19 requires.
    private static func srgbChromaticityBytes() -> [UInt8] {
        let red = (x: 0.640, y: 0.330)
        let green = (x: 0.300, y: 0.600)
        let blue = (x: 0.150, y: 0.060)
        let white = (x: 0.3127, y: 0.3290)
        func tenBits(_ value: Double) -> Int {
            Int((value * 1024).rounded())
        }
        let rx = tenBits(red.x)
        let ry = tenBits(red.y)
        let gx = tenBits(green.x)
        let gy = tenBits(green.y)
        let bx = tenBits(blue.x)
        let by = tenBits(blue.y)
        let wx = tenBits(white.x)
        let wy = tenBits(white.y)
        let redGreenLow = (rx & 3) << 6 | (ry & 3) << 4 | (gx & 3) << 2 | (gy & 3)
        let blueWhiteLow = (bx & 3) << 6 | (by & 3) << 4 | (wx & 3) << 2 | (wy & 3)
        return [
            UInt8(redGreenLow), UInt8(blueWhiteLow),
            UInt8(rx >> 2), UInt8(ry >> 2), UInt8(gx >> 2), UInt8(gy >> 2),
            UInt8(bx >> 2), UInt8(by >> 2), UInt8(wx >> 2), UInt8(wy >> 2),
        ]
    }

    /// An 18-byte detailed timing descriptor for a positive-HSync, negative-VSync timing.
    static func detailedTimingBytes(_ timing: Timing) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 18)
        littleEndian(UInt32(timing.pixelClock10kHz), into: &bytes, at: 0, byteCount: 2)
        bytes[2] = UInt8(timing.hActive & 0xFF)
        bytes[3] = UInt8(timing.hBlank & 0xFF)
        bytes[4] = UInt8(((timing.hActive >> 8) & 0xF) << 4 | ((timing.hBlank >> 8) & 0xF))
        bytes[5] = UInt8(timing.vActive & 0xFF)
        bytes[6] = UInt8(timing.vBlank & 0xFF)
        bytes[7] = UInt8(((timing.vActive >> 8) & 0xF) << 4 | ((timing.vBlank >> 8) & 0xF))
        bytes[8] = UInt8(timing.hFront & 0xFF)
        bytes[9] = UInt8(timing.hSync & 0xFF)
        bytes[10] = UInt8((timing.vFront & 0xF) << 4 | (timing.vSync & 0xF))
        bytes[11] = UInt8(
            ((timing.hFront >> 8) & 3) << 6
                | ((timing.hSync >> 8) & 3) << 4
                | ((timing.vFront >> 4) & 3) << 2
                | ((timing.vSync >> 4) & 3)
        )
        bytes[12] = UInt8(timing.widthMM & 0xFF)
        bytes[13] = UInt8(timing.heightMM & 0xFF)
        bytes[14] = UInt8(((timing.widthMM >> 8) & 0xF) << 4 | ((timing.heightMM >> 8) & 0xF))
        // Borders stay zero. Digital separate sync (0x18), positive HSync (0x02), negative VSync.
        bytes[17] = 0x1A
        return bytes
    }

    /// A display range limits descriptor (tag `0xFD`). Its limits cover every mode APKRun accepts.
    private static func rangeLimitBytes() -> [UInt8] {
        let maximumPixelClockIn10MHz = 66  // 655.35 MHz, the largest clock a detailed timing holds
        return [0x00, 0x00, 0x00, 0xFD, 0x00]
            + [24, 120, UInt8(horizontalRangeKHz.lowerBound), UInt8(horizontalRangeKHz.upperBound)]
            + [UInt8(maximumPixelClockIn10MHz), 0x00]
            + [0x0A] + Array(repeating: 0x20, count: 6)
    }

    /// A text descriptor with `tag`, the text, a line feed, and spaces to 13 bytes.
    static func textDescriptorBytes(tag: UInt8, text: String) -> [UInt8] {
        var field = Array(text.utf8.prefix(12))
        field.append(0x0A)
        field += Array(repeating: 0x20, count: 13 - field.count)
        return [0x00, 0x00, 0x00, tag, 0x00] + field
    }

    private static func dummyDescriptorBytes() -> [UInt8] {
        [0x00, 0x00, 0x00, 0x10, 0x00] + Array(repeating: 0x00, count: 13)
    }

    /// The byte that makes the 128-byte block sum to zero modulo 256.
    static func checksum(of bytes: some Collection<UInt8>) -> UInt8 {
        let sum = bytes.reduce(UInt8(0)) { $0 &+ $1 }
        return 0 &- sum
    }

    private static func littleEndian(_ value: UInt32, into bytes: inout [UInt8], at offset: Int, byteCount: Int) {
        for index in 0..<byteCount {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index))
        }
    }
}
