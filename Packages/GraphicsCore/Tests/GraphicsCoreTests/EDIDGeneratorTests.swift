import Testing

@testable import GraphicsCore

/// The fields that these tests read back from a generated base block.
///
/// The decoder is written from the EDID 1.4 layout, separately from the generator,
/// so a layout error in one does not hide in the other.
private struct DecodedEDID {
    var manufacturer: String
    var productCode: Int
    var serial: Int
    var widthCM: Int
    var heightCM: Int
    var activeWidth: Int
    var activeHeight: Int
    var blankWidth: Int
    var blankHeight: Int
    var pixelClockHz: Int
    var widthMM: Int
    var heightMM: Int
    var hSyncPositive: Bool
    var vSyncPositive: Bool
    var name: String?
    var verticalRangeHz: ClosedRange<Int>?
    var maximumPixelClockMHz: Int?

    var refreshHz: Double {
        Double(pixelClockHz) / Double((activeWidth + blankWidth) * (activeHeight + blankHeight))
    }

    init(_ bytes: [UInt8]) {
        manufacturer = String(
            bytes: [
                UInt8(((Int(bytes[8]) << 8 | Int(bytes[9])) >> 10 & 0x1F) + 0x40),
                UInt8(((Int(bytes[8]) << 8 | Int(bytes[9])) >> 5 & 0x1F) + 0x40),
                UInt8((Int(bytes[8]) << 8 | Int(bytes[9])) & 0x1F + 0x40),
            ],
            encoding: .ascii
        )!
        productCode = Int(bytes[10]) | Int(bytes[11]) << 8
        serial = Int(bytes[12]) | Int(bytes[13]) << 8 | Int(bytes[14]) << 16 | Int(bytes[15]) << 24
        widthCM = Int(bytes[21])
        heightCM = Int(bytes[22])

        let dtd = Array(bytes[54..<72])
        pixelClockHz = (Int(dtd[0]) | Int(dtd[1]) << 8) * 10_000
        activeWidth = Int(dtd[2]) | Int(dtd[4] >> 4) << 8
        blankWidth = Int(dtd[3]) | Int(dtd[4] & 0xF) << 8
        activeHeight = Int(dtd[5]) | Int(dtd[7] >> 4) << 8
        blankHeight = Int(dtd[6]) | Int(dtd[7] & 0xF) << 8
        widthMM = Int(dtd[12]) | Int(dtd[14] >> 4) << 8
        heightMM = Int(dtd[13]) | Int(dtd[14] & 0xF) << 8
        hSyncPositive = dtd[17] & 0x02 != 0
        vSyncPositive = dtd[17] & 0x04 != 0

        let range = Array(bytes[72..<90])
        if range[3] == 0xFD {
            verticalRangeHz = Int(range[5])...Int(range[6])
            maximumPixelClockMHz = Int(range[9]) * 10
        }
        let text = Array(bytes[90..<108])
        if text[3] == 0xFC {
            let characters = text[5...].prefix { $0 != 0x0A }
            name = String(bytes: characters, encoding: .ascii)
        }
    }
}

private func checksumIsZero(_ bytes: [UInt8]) -> Bool {
    bytes.reduce(UInt8(0)) { $0 &+ $1 } == 0
}

@Test func generatedBlocksMatchTheGoldenFiles() throws {
    let cases: [(file: String, index: Int, mode: DisplayMode)] = [
        ("scanout-00-1024x768-60.edid", 0, .testDefault),
        (
            "scanout-01-1920x1080-60.edid", 1,
            DisplayMode(widthPixels: 1920, heightPixels: 1080, refreshHz: 60, dotsPerInch: 160)
        ),
        (
            "scanout-15-1440x3120-60.edid", 15,
            DisplayMode(widthPixels: 1440, heightPixels: 3120, refreshHz: 60, dotsPerInch: 560)
        ),
    ]
    for testCase in cases {
        let scanout = try #require(ScanoutID(rawValue: testCase.index))
        let generated = try EDIDGenerator.make(scanout: scanout, mode: testCase.mode)
        let golden = try GraphicsFixtures.edid(named: testCase.file)
        #expect(generated.count == EDIDGenerator.byteCount)
        #expect(generated == golden, "\(testCase.file)")
    }
}

@Test func generatedBlocksDecodeToTheRequestedScanoutAndMode() throws {
    let scanout = try #require(ScanoutID(rawValue: 15))
    let mode = DisplayMode(widthPixels: 1440, heightPixels: 3120, refreshHz: 60, dotsPerInch: 560)
    let edid = DecodedEDID(try EDIDGenerator.make(scanout: scanout, mode: mode))

    #expect(edid.manufacturer == "APK")
    #expect(edid.productCode == 15)
    #expect(edid.serial == 15)
    #expect(edid.name == "APKRun 15")
    #expect(edid.activeWidth == 1440)
    #expect(edid.activeHeight == 3120)
    #expect(edid.widthMM == 65)
    #expect(edid.heightMM == 142)
    #expect(edid.widthCM == 7)
    #expect(edid.heightCM == 14)
    #expect(edid.hSyncPositive)
    #expect(!edid.vSyncPositive)
    #expect(abs(edid.refreshHz - 60) < 0.5)
    #expect(edid.verticalRangeHz == 24...120)
    #expect(edid.maximumPixelClockMHz == 660)
}

@Test func reducedBlankingTimingUsesTheFixedHorizontalBlank() throws {
    let scanout = try #require(ScanoutID(rawValue: 0))
    let edid = DecodedEDID(try EDIDGenerator.make(scanout: scanout, mode: .testDefault))
    #expect(edid.blankWidth == 160)
    #expect(edid.activeWidth == 1024)
    #expect(edid.activeHeight == 768)
    #expect(edid.pixelClockHz == 56_000_000)
    #expect(edid.name == "APKRun 0")
}

@Test func everyAcceptedModeProducesAValidChecksum() throws {
    let scanout = try #require(ScanoutID(rawValue: 3))
    let widths = [320, 800, 1024, 1280, 1920, 2560, 3840, 4095]
    let heights = [240, 600, 768, 1080, 1600, 2160, 4095]
    for width in widths {
        for height in heights {
            let mode = DisplayMode(widthPixels: width, heightPixels: height, refreshHz: 60, dotsPerInch: 160)
            do {
                let edid = try EDIDGenerator.make(scanout: scanout, mode: mode)
                #expect(checksumIsZero(edid), "\(mode)")
                let decoded = DecodedEDID(edid)
                #expect(decoded.activeWidth == width)
                #expect(decoded.activeHeight == height)
            } catch {
                // A clock above the 16-bit descriptor limit is rejected, not encoded.
                #expect(error == .modeUnsupported(mode: mode), "\(mode)")
            }
        }
    }
}

@Test func modesOutsideTheEDIDLimitsAreRejected() throws {
    let scanout = try #require(ScanoutID(rawValue: 0))
    let tooWide = DisplayMode(widthPixels: 4096, heightPixels: 768, refreshHz: 60, dotsPerInch: 160)
    #expect(throws: GraphicsFailure.modeUnsupported(mode: tooWide)) {
        _ = try EDIDGenerator.make(scanout: scanout, mode: tooWide)
    }

    let tinyDensity = DisplayMode(widthPixels: 1024, heightPixels: 768, refreshHz: 60, dotsPerInch: 1)
    #expect(throws: GraphicsFailure.modeUnsupported(mode: tinyDensity)) {
        _ = try EDIDGenerator.make(scanout: scanout, mode: tinyDensity)
    }

    let tooFastClock = DisplayMode(widthPixels: 4095, heightPixels: 4095, refreshHz: 120, dotsPerInch: 160)
    #expect(throws: GraphicsFailure.modeUnsupported(mode: tooFastClock)) {
        _ = try EDIDGenerator.make(scanout: scanout, mode: tooFastClock)
    }
}

@Test func millimetersRoundToTheNearestWholeMillimeter() {
    #expect(EDIDGenerator.millimeters(pixels: 1024, dotsPerInch: 160) == 163)
    #expect(EDIDGenerator.millimeters(pixels: 1440, dotsPerInch: 560) == 65)
    #expect(EDIDGenerator.centimeters(millimeters: 163) == 16)
}

@Test func checksumMakesTheBlockSumToZero() {
    let block: [UInt8] = [1, 2, 3, 250]
    #expect(EDIDGenerator.checksum(of: block) == 0)
    #expect((block.reduce(UInt8(0)) { $0 &+ $1 }) &+ EDIDGenerator.checksum(of: block) == 0)
}
