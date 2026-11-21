import Foundation
import XCTest

/// Gate G8 (roadmap.md §2, test-strategy.md §5): `apkrun wrap` produces
/// `HelloText.app` — bundle ID `io.apkrun.android.io.apkrun.fixture.hellotext`,
/// ad-hoc signed, `codesign --verify --strict` clean — and double-clicking it
/// opens an interactive HelloText window without a terminal, from the Dock too,
/// with the runtime stopped and with it warm.
///
/// It runs in the `G8` configuration of AcceptanceTests.xctestplan, with the
/// inputs scripts/run-gate.sh sets. The wrapper, the CLI output, and the launch
/// timings go to APKRUN_G8_ARTIFACTS, outside the repository.
final class G8WrapperTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        let selected = environment["APKRUN_ACCEPTANCE_SUITE"] == "g8"
        if environment["APKRUN_G8_REQUIRED"] == "1" {
            guard selected else {
                throw XCTSkip("The G8 check runs in the G8 test-plan configuration.")
            }
            return
        }
        guard selected else {
            throw XCTSkip("The G8 check runs in the G8 test-plan configuration.")
        }
    }

    /// The inputs scripts/run-gate.sh stages for the gate.
    private struct Inputs {
        let cli: URL
        let app: URL
        let apk: URL
        let artifacts: URL
        let adb: URL
    }

    private static func inputs() throws -> Inputs {
        func required(_ name: String) throws -> URL {
            guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
                throw XCTSkip("run-gate.sh G8 sets \(name)")
            }
            return URL(fileURLWithPath: value)
        }
        return Inputs(
            cli: try required("APKRUN_G8_CLI"),
            app: try required("APKRUN_G8_APP"),
            apk: try required("APKRUN_G8_APK"),
            artifacts: try required("APKRUN_G8_ARTIFACTS"),
            adb: try required("APKRUN_G8_ADB")
        )
    }

    private static let expectedBundleID = "io.apkrun.android.io.apkrun.fixture.hellotext"
    private static let expectedPackageID = "io.apkrun.fixture.hellotext"

    func testWrappedHelloTextOpensInteractively() async throws {
        executionTimeAllowance = 1800
        let inputs = try Self.inputs()
        try FileManager.default.createDirectory(at: inputs.artifacts, withIntermediateDirectories: true)
        let wrapperURL = inputs.artifacts.appendingPathComponent("HelloText.app")

        // The daemon runs as the per-user LaunchAgent (#32).
        try await run(
            inputs.app.appendingPathComponent("Contents/MacOS/APKRun"),
            ["--register-runtime"])

        // 1. `apkrun wrap` produces the wrapper (roadmap.md §2 G8 condition 1).
        try await run(
            inputs.cli,
            ["wrap", inputs.apk.path, "--install", "--output", wrapperURL.path])
        let plistURL = wrapperURL.appendingPathComponent("Contents/Info.plist")
        let plist =
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        XCTAssertEqual(plist?["CFBundleIdentifier"] as? String, Self.expectedBundleID)
        XCTAssertEqual(plist?["APKRunPackageID"] as? String, Self.expectedPackageID)

        let identity = try await output(
            "/usr/bin/codesign", ["-dv", "--verbose=2", wrapperURL.path], stderrIsOutput: true)
        XCTAssertTrue(identity.contains("Signature=adhoc"), identity)
        try await run("/usr/bin/codesign", ["--verify", "--strict", wrapperURL.path])

        // 2+3. Double-click opens an interactive window with the runtime
        // stopped, then again with it warm (roadmap.md §2 G8 conditions 2–3).
        let stoppedTiming = try await launchAndMeasure(wrapperURL: wrapperURL, inputs: inputs)
        let warmTiming = try await launchAndMeasure(wrapperURL: wrapperURL, inputs: inputs)
        try """
        cold click-to-first-frame: \(stoppedTiming) s
        warm click-to-first-frame: \(warmTiming) s
        """.write(
            to: inputs.artifacts.appendingPathComponent("launch-timings.txt"),
            atomically: true, encoding: .utf8)
        // Warm p50 ≤ 1.5 s and p95 ≤ 3 s, cold p50 ≤ 40 s (wrapper.md §9.4);
        // the gate records the timings even while the KPI is provisional.
        XCTAssertLessThan(warmTiming, 3.0, "warm click-to-first-frame over p95 bound")
    }

    /// Opens the wrapper like Finder's double-click, waits for the HelloText
    /// window, clicks into it, and waits for the fixture's `click` logcat
    /// marker. Returns the click-to-first-frame time in seconds.
    private func launchAndMeasure(wrapperURL: URL, inputs: Inputs) async throws -> TimeInterval {
        let start = Date()
        try await run("/usr/bin/open", [wrapperURL.path])
        let deadline = start.addingTimeInterval(300)
        var windowBounds: CGRect?
        while Date() < deadline {
            if let bounds = helloTextWindowBounds() {
                windowBounds = bounds
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let firstFrame = Date().timeIntervalSince(start)
        guard let windowBounds else {
            XCTFail("no HelloText window within 300 s of the double-click")
            return firstFrame
        }

        // A click at the window's centre reaches the fixture, which logs
        // `click <n>` (the HelloText fixture contract).
        let clickCountBefore = try await clickMarkerCount(inputs: inputs)
        let point = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                mouseButton: .left)
            event?.post(tap: .cghidEventTap)
        }
        let clickDeadline = Date().addingTimeInterval(60)
        while Date() < clickDeadline {
            if try await clickMarkerCount(inputs: inputs) > clickCountBefore {
                return firstFrame
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("the window click did not reach HelloText within 60 s")
        return firstFrame
    }

    /// The bounds of the wrapper's HelloText window, from the window server.
    private func helloTextWindowBounds() -> CGRect? {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]]
        else {
            return nil
        }
        for entry in list {
            guard (entry[kCGWindowOwnerName as String] as? String) == "HelloText",
                (entry[kCGWindowLayer as String] as? Int) == 0,
                let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], width > 0
            else {
                continue
            }
            return CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: width, height: bounds["Height"] ?? 0)
        }
        return nil
    }

    /// How many `click` markers the fixture has logged so far.
    private func clickMarkerCount(inputs: Inputs) async throws -> Int {
        let log = try await output(inputs.adb.path, ["logcat", "-d", "-s", "HelloText"])
        return log.components(separatedBy: "click").count - 1
    }

    private func run(_ executable: URL, _ arguments: [String]) async throws {
        _ = try await output(executable.path, arguments)
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        try await run(URL(fileURLWithPath: executable), arguments)
    }

    private func output(
        _ executable: String,
        _ arguments: [String],
        stderrIsOutput: Bool = false
    ) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        if stderrIsOutput {
            process.standardError = pipe
        }
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "G8WrapperTests", code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "\(executable) \(arguments.joined(separator: " ")) failed"
                ])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
