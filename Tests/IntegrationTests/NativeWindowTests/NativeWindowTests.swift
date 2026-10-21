import AppKit
import CoreGraphics
import Foundation
import IOSurface
import QuartzCore
import ScreenCaptureKit
import Vision
import WindowingCore
import XCTest

/// Exercises HelloText in the real development window and display-0 VM path (#27, T2).
///
/// Pointer and key events are delivered to the window's IOSurfaceLayerView. The fixture's click log and text
/// broadcast verify that Android handled them; a WindowServer screenshot verifies visible HelloText content.
@MainActor
final class NativeWindowTests: XCTestCase {
    private static let helloText = "io.apkrun.fixture.hellotext"
    private static let windowTitle = "APKRun display 0"
    private static let buttonID = "io.apkrun.fixture.hellotext:id/increment_button"
    private static let fieldID = "io.apkrun.fixture.hellotext:id/input_text"
    private static let clickPrefix = "APKRUN-FIXTURE: click "
    private static let textAction = "io.apkrun.fixture.hellotext.debug.TEXT"
    private static let textPrefix = "APKRUN-FIXTURE: text "
    private static let expectedText = "Hello, APKRun 123!"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_NATIVE_WINDOW_T2"] == "1" else {
            throw XCTSkip(
                "The native window check runs with APKRUN_NATIVE_WINDOW_T2=1 in the NativeWindow test-plan configuration."
            )
        }
    }

    func testHelloTextUsesNativeWindowAndAcceptsInput() async throws {
        let apk = try fixture("APKRUN_FIXTURE_APK")
        try await AndroidInputRun.with(
            apk: apk,
            package: Self.helloText,
            inputBindingTimeout: .seconds(180),
            stopPackageOnWindowClose: true
        ) { run in
            let window = try XCTUnwrap(
                NSApplication.shared.windows.first { $0.title == Self.windowTitle },
                "SessionWindowController did not create the display-0 window")
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(window.styleMask.contains(.titled))
            XCTAssertTrue(window.styleMask.contains(.closable))
            XCTAssertTrue(window.styleMask.contains(.miniaturizable))
            XCTAssertNil(window.toolbar, "The app window must not show emulator toolbar chrome.")
            try await run.waitForAppFrameAtPlaceholder()
            XCTAssertEqual(
                window.contentView?.subviews.count, 2,
                "The launch window must keep its placeholder above the IOSurface view.")
            try await Self.waitForVisiblePlaceholder(in: window)

            await run.allowAppFrameToReplacePlaceholder()
            try await run.waitForDisplayedFrameAfterLaunch()
            try await Self.waitForVisibleHelloText(in: window)
            try await run.waitForText("INCREMENT")
            try await run.activateWindowForInput()

            let surfaceView = try XCTUnwrap(
                Self.surfaceLayerView(in: window.contentView),
                "The native window must host IOSurfaceLayerView.")
            try await Self.waitForIOSurface(in: surfaceView.layer)
            XCTAssertEqual(
                window.contentView?.subviews.count, 1,
                "After the first frame, the placeholder must be removed and only the surface view remain.")

            _ = try await run.adb.shell("logcat -c")
            let button = try await run.centre(of: Self.buttonID)
            try await run.pointer().click(at: button)
            try await run.drainInput()
            let clickLines = try await run.fixtureLog { lines in
                lines.contains { $0.contains(Self.clickPrefix) }
            }
            let inputCounters = try await run.inputCounters()
            let wireTouchPhases = try await run.inputWireTouchPhaseCounts()
            XCTAssertTrue(
                clickLines.contains { $0.contains(Self.clickPrefix) },
                "The HelloText button did not receive the native-window click. "
                    + "Input route: \(inputCounters); wire touch phases: \(wireTouchPhases).")

            try await Self.focusField(run)
            try await run.keyboard().type(Self.expectedText)
            try await run.drainInput()
            try await Self.waitForFieldText(run, expected: Self.expectedText)
            try await run.closeWindowAndWaitForTaskVanished(package: Self.helloText)
        }
    }

    /// Verifies that the real native window shows its launch placeholder before DevBoot reveals the app frame.
    private static func waitForVisiblePlaceholder(
        in window: NSWindow,
        timeout: Duration = .seconds(30)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        var latestText: [String] = []
        while ContinuousClock.now < deadline {
            let content = try await SCShareableContent.currentProcess
            if let shareableWindow = content.windows.first(
                where: { $0.windowID == CGWindowID(window.windowNumber) }
            ) {
                let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(window.frame.width * window.backingScaleFactor))
                configuration.height = max(1, Int(window.frame.height * window.backingScaleFactor))
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                latestText = try Self.recognizedText(in: image)
                if latestText.contains(where: {
                    $0.localizedCaseInsensitiveContains("Starting Android")
                        || $0.localizedCaseInsensitiveContains("Preparing app")
                }) {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AndroidInputRunFailure.timedOut(
            "the launch placeholder in the native-window screenshot; OCR saw [\(latestText.joined(separator: " | "))]"
        )
    }

    private static func surfaceLayerView(in view: NSView?) -> IOSurfaceLayerView? {
        guard let view else {
            return nil
        }
        if let surfaceView = view as? IOSurfaceLayerView {
            return surfaceView
        }
        for subview in view.subviews {
            if let surfaceView = surfaceLayerView(in: subview) {
                return surfaceView
            }
        }
        return nil
    }

    private static func waitForIOSurface(in layer: CALayer?) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if containsIOSurface(in: layer) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AndroidInputRunFailure.timedOut("an IOSurface frame in the native window")
    }

    private static func containsIOSurface(in layer: CALayer?) -> Bool {
        guard let layer else {
            return false
        }
        if layer.contents is IOSurface {
            return true
        }
        return layer.sublayers?.contains(where: containsIOSurface(in:)) ?? false
    }

    /// Checks the rendered window, rather than the guest hierarchy or an IOSurface retained from boot.
    private static func waitForVisibleHelloText(in window: NSWindow, timeout: Duration = .seconds(30)) async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * window.backingScaleFactor))
        configuration.height = max(1, Int(window.frame.height * window.backingScaleFactor))

        let deadline = ContinuousClock.now + timeout
        var latestText: [String] = []
        while ContinuousClock.now < deadline {
            let content = try await SCShareableContent.currentProcess
            if let shareableWindow = content.windows.first(
                where: { $0.windowID == CGWindowID(window.windowNumber) }
            ) {
                let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                latestText = try Self.recognizedText(in: image)
                if latestText.contains(where: { $0.localizedCaseInsensitiveContains("Increment") }) {
                    return
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AndroidInputRunFailure.timedOut(
            "visible HelloText content in the native-window screenshot; OCR saw [\(latestText.joined(separator: " | "))]"
        )
    }

    private static func recognizedText(in image: CGImage) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
    }

    /// Focuses the editor using the app's normal Tab order, checking Android focus after each key.
    private static func focusField(_ run: AndroidInputRun) async throws {
        let keyboard = try run.keyboard()
        let countersBefore = try await run.inputCounters()
        for _ in 0..<6 {
            let xml = try await run.uiDump()
            switch AndroidInputRun.isFocused(fieldID, in: xml) {
            case true?:
                return
            case false?:
                try await keyboard.tap(.tab)
                try await Task.sleep(for: .milliseconds(400))
            case nil:
                try await Task.sleep(for: .seconds(1))
            }
        }
        let countersAfter = try await run.inputCounters()
        throw AndroidInputRunFailure.viewNotFound(
            "the focus of \(fieldID); input before \(countersBefore), after \(countersAfter)")
    }

    /// Reads Android's edit field through the debug fixture command; this is observation, not input.
    private static func fieldText(_ run: AndroidInputRun, timeout: Duration) async throws -> String? {
        _ = try await run.adb.shell("logcat -c")
        _ = try await run.adb.shell("am broadcast -a \(textAction) -p \(helloText)")
        let lines = try await run.fixtureLog(
            until: { lines in lines.contains { $0.contains(textPrefix) } },
            timeout: timeout)
        guard let line = lines.last(where: { $0.contains(textPrefix) }),
            let range = line.range(of: textPrefix)
        else {
            return nil
        }
        let json = String(line[range.upperBound...])
        return try JSONDecoder().decode([String].self, from: Data("[\(json)]".utf8)).first ?? ""
    }

    /// Lets routed key events reach the guest, then polls the fixture until Android reports the typed value.
    private static func waitForFieldText(
        _ run: AndroidInputRun,
        expected: String,
        timeout: Duration = .seconds(30)
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        var latestText: String?
        while ContinuousClock.now < deadline {
            try await run.drainInput()
            let remaining = deadline - .now
            guard remaining > .zero else { break }
            latestText = try await fieldText(run, timeout: min(.seconds(2), remaining))
            if latestText == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AndroidInputRunFailure.timedOut(
            "HelloText field text \(String(reflecting: expected)); last observed "
                + "\(latestText.map { String(reflecting: $0) } ?? "no fixture response")")
    }

    private func fixture(_ key: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[key], FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("\(key) does not name a fixture APK. Build HelloText and copy it to /tmp.")
        }
        return URL(fileURLWithPath: path)
    }
}
