import Foundation
import RuntimeAPI
import XCTest

/// §3.2's settings → Sparkle mapping and the Settings status line.
final class SelfUpdateTests: XCTestCase {

    // MARK: SelfUpdateSettings

    func testDefaultsCheckAutomaticallyOnDownloadOffStableChannel() {
        let settings = SelfUpdateSettings(values: [:])
        XCTAssertTrue(settings.checkAutomatically)
        XCTAssertFalse(settings.downloadAutomatically)
        XCTAssertEqual(settings.channel, "stable")
        XCTAssertEqual(settings.allowedChannels, [])
    }

    func testMapping() {
        let settings = SelfUpdateSettings(values: [
            "maintenance.checkAutomatically": "false",
            "maintenance.installAPKRunAutomatically": "true",
            "maintenance.channel": "beta",
        ])
        XCTAssertFalse(settings.checkAutomatically)
        XCTAssertTrue(settings.downloadAutomatically)
        XCTAssertEqual(settings.allowedChannels, ["beta"])
    }

    func testStableChannelAllowsNoExtraChannels() {
        let settings = SelfUpdateSettings(values: ["maintenance.channel": "stable"])
        XCTAssertEqual(settings.allowedChannels, [])
    }

    func testEmptyAndUnknownValuesFallBackToDefaults() {
        let settings = SelfUpdateSettings(values: [
            "maintenance.checkAutomatically": "",
            "maintenance.channel": "",
        ])
        XCTAssertTrue(settings.checkAutomatically)
        XCTAssertEqual(settings.channel, "stable")
        let junk = SelfUpdateSettings(values: ["maintenance.checkAutomatically": "maybe"])
        XCTAssertFalse(junk.checkAutomatically)
    }

    // MARK: SelfUpdateModel status line (§3.2)

    @MainActor
    func testStatusLineTransitions() {
        let model = SelfUpdateModel()
        XCTAssertEqual(model.statusLine, "")

        model.checked(found: nil)
        XCTAssertEqual(model.statusLine, "APKRun is up to date.")

        let release = AvailableRelease(version: "1.2.0", build: 1200)
        model.foundUpdate(release)
        XCTAssertEqual(model.statusLine, "APKRun 1.2.0 is available.")

        model.pendingOnQuit(release)
        XCTAssertEqual(
            model.statusLine,
            "APKRun 1.2.0 will be installed when you quit APKRun.")
        XCTAssertEqual(model.pendingRelease, release)
    }
}
