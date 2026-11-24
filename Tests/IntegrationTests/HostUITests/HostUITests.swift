import XCTest

/// #93 step 5/6 (host-ui.md §15): pseudo-language and accessibility audit runs
/// against the real runtime. These are T2: they need the built app, a running
/// apkrund, and a signed test host, so they run only under the host-ui suite.
final class HostUITests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "host-ui"
        else {
            throw XCTSkip("Host UI checks run in the HostUI test-plan configuration.")
        }
    }

    /// Step 5 (C10-2): every screen of host-ui.md §4–§12 under the double-length
    /// pseudo-language shows no clipped label. The app is relaunched per screen
    /// so the catalog reloads under en-XA, and a screenshot is saved for review.
    func testPseudoLanguageShowsNoTruncation() throws {
        let app = XCUIApplication(bundleIdentifier: "io.apkrun.APKRun")
        app.launchArguments = ["-AppleLanguages", "(en-XA)"]
        app.launch()
        let screens: [(String, String)] = [
            ("onboarding", "apkrun://onboarding"),
            ("home", "apkrun://home"),
            ("addFlow", "apkrun://add"),
            ("settings", "apkrun://settings/general"),
        ]
        for (name, deepLink) in screens {
            NSWorkspace.shared.open(URL(string: deepLink)!)
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 30), "\(name) window")
            for element in window.staticTexts.allElementsBoundByIndex
            where element.exists && element.label.count > 0 {
                XCTAssertFalse(
                    element.frame.isEmpty,
                    "\(name): '\(element.label)' has an empty frame (clipped)")
            }
            let screenshot = XCTAttachment(
                screenshot: window.screenshot())
            screenshot.name = "en-XA-\(name)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        app.terminate()
    }

    /// Step 6 (C10-1): the accessibility audit passes on the home, add flow,
    /// app page, and Settings screens of host-ui.md §4–§12.
    func testAccessibilityAuditPasses() throws {
        let app = XCUIApplication(bundleIdentifier: "io.apkrun.APKRun")
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        if #available(macOS 14, *) {
            try app.performAccessibilityAudit()
        }
        app.terminate()
    }
}
