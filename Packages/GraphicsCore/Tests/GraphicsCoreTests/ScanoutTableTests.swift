import Testing

@testable import GraphicsCore

private func scanout(_ index: Int) throws -> ScanoutID {
    try #require(ScanoutID(rawValue: index))
}

@Test func scanoutIdentifiersCoverExactlySixteenScanouts() {
    #expect(ScanoutID(rawValue: -1) == nil)
    #expect(ScanoutID(rawValue: 0)?.rawValue == 0)
    #expect(ScanoutID(rawValue: 15)?.rawValue == 15)
    #expect(ScanoutID(rawValue: 16) == nil)
}

@Test func freshTableEnablesOnlyScanoutZeroAtTheTestMode() throws {
    let table = ScanoutTable()
    #expect(table.displayGeneration == 0)
    #expect(table.enabledScanouts == [try scanout(0)])
    #expect(table.state(of: try scanout(0)) == ScanoutState(isEnabled: true, mode: .testDefault))
    #expect(table.allStates.count == VirtioGPUProtocol.scanoutCount)
    #expect(table.allStates.dropFirst().allSatisfy { !$0.isEnabled })
}

@Test func enablingAndDisablingAScanoutBumpsTheGeneration() throws {
    var table = ScanoutTable()
    let other = try scanout(1)
    let mode = DisplayMode(widthPixels: 1280, heightPixels: 800, refreshHz: 60, dotsPerInch: 213)

    let enabled = try table.enable(other, mode: mode)
    #expect(enabled)
    #expect(table.displayGeneration == 1)
    #expect(table.state(of: other) == ScanoutState(isEnabled: true, mode: mode))

    let disabled = table.disable(other)
    #expect(disabled)
    #expect(table.displayGeneration == 2)
    // A disabled scanout keeps its last mode, so its EDID stays stable.
    #expect(table.state(of: other) == ScanoutState(isEnabled: false, mode: mode))
}

@Test func changesThatDoNotChangeTheStateDoNotBumpTheGeneration() throws {
    var table = ScanoutTable()
    let first = try scanout(0)
    let enableChanged = try table.enable(first, mode: .testDefault)
    #expect(enableChanged == false)
    #expect(table.displayGeneration == 0)
    let disableChanged = table.disable(try scanout(7))
    #expect(disableChanged == false)
    #expect(table.displayGeneration == 0)
}

@Test func aModeOutsideTheLimitsIsRejectedWithoutChangingTheTable() throws {
    var table = ScanoutTable()
    let other = try scanout(2)
    let invalid = DisplayMode(widthPixels: 5000, heightPixels: 768, refreshHz: 60, dotsPerInch: 160)

    #expect(throws: GraphicsFailure.modeUnsupported(mode: invalid)) {
        _ = try table.enable(other, mode: invalid)
    }
    #expect(table.displayGeneration == 0)
    #expect(table.state(of: other).isEnabled == false)
}

@Test func displayModeLimitsMatchTheEDIDRules() {
    #expect(DisplayMode.testDefault.isSupported)
    // 4095x4095 at 60 Hz needs about 1051 MHz, over the 655.35 MHz detailed-timing limit.
    #expect(DisplayMode(widthPixels: 4095, heightPixels: 4095, refreshHz: 24, dotsPerInch: 160).isSupported)
    #expect(!DisplayMode(widthPixels: 4095, heightPixels: 4095, refreshHz: 60, dotsPerInch: 160).isSupported)
    // 1x4095 at 120 Hz has about 520 kHz horizontal, over the 255 kHz range limit.
    #expect(!DisplayMode(widthPixels: 1, heightPixels: 4095, refreshHz: 120, dotsPerInch: 160).isSupported)
    // 1024x768 at 24 Hz has about 18.8 kHz horizontal, under the 30 kHz range limit.
    #expect(!DisplayMode(widthPixels: 1024, heightPixels: 768, refreshHz: 24, dotsPerInch: 160).isSupported)
    #expect(!DisplayMode(widthPixels: 4096, heightPixels: 768, refreshHz: 60, dotsPerInch: 160).isSupported)
    #expect(!DisplayMode(widthPixels: 0, heightPixels: 768, refreshHz: 60, dotsPerInch: 160).isSupported)
    #expect(!DisplayMode(widthPixels: 1024, heightPixels: 768, refreshHz: 0, dotsPerInch: 160).isSupported)
    #expect(DisplayMode.testDefault.description == "1024x768@60")
}
