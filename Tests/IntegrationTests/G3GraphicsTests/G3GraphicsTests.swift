import Foundation
import XCTest

/// Gate G3 (roadmap.md §2, test-strategy.md §5, graphics.md §12 #023): SurfaceFlinger renders through virtio-gpu to
/// Metal, and the Android display is shown in a macOS window.
///
/// One boot runs the whole check, as the manual HelloGL run of #023 did (IR-1200 to IR-1208):
/// `apkrun dev boot --gpu virgl --window --stats --console` on the Android bundle that scripts/run-gate.sh names, in a
/// new APKRUN_HOME. Then, in this order: the display is in a window; HelloGL's `renderer` event and the GLES line of
/// SurfaceFlinger name virgl; 60 s of statistics show no readback and no CPU copy; the alternating-colour phase shows no
/// frame with both colours, by the test-only readback sampler of the CLI (graphics.md §12 #023, step 5); HelloGL
/// averages at least 55 fps and runs 10 minutes with the same pid and no renderer crash. The run stops with SIGINT.
///
/// It runs in the `G3` configuration of IntegrationTests.xctestplan, with the inputs that scripts/run-gate.sh sets. The
/// artifacts go to APKRUN_G3_ARTIFACTS, outside the repository, and the gate copies them under build/gates/G3.
final class G3GraphicsTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        let selected = environment["APKRUN_INTEGRATION_SUITE"] == "g3"
        // The G3 configuration sets APKRUN_G3_REQUIRED. There the check must run, so a suite that does not match
        // fails instead of skipping. Other configurations skip the check, as the other suites do.
        if environment["APKRUN_G3_REQUIRED"] == "1" {
            guard selected else {
                throw G3Failure.notSelected
            }
            return
        }
        guard selected else {
            throw XCTSkip("The G3 check runs in the G3 test-plan configuration.")
        }
    }

    func testHelloGLRendersThroughVirglInAWindowWithoutReadbacksTearingOrRendererCrash() async throws {
        // The run is about 25 minutes. XCTest's default allowance is shorter, so the test sets its own.
        executionTimeAllowance = 3600
        let session = try G3Session(inputs: try G3Inputs.fromEnvironment())
        defer { session.removeHome() }
        session.note("G3 run: artifacts in \(session.inputs.artifacts.path), home \(session.home.path)")

        var measurements = G3Measurements()
        var stepFailure: Error?
        do {
            try await measure(session, into: &measurements)
        } catch {
            stepFailure = error
            session.note("step failed: \(error)")
        }
        measurements.bootStop = await session.stopBoot()
        session.note("boot stop: \(measurements.bootStop.rawValue)")

        let failures = G3Evidence.failures(measurements)
        try session.writeArtifact(
            "summary.txt", Self.summary(measurements, failures: failures, stepFailure: stepFailure))
        let attachment = XCTAttachment(string: Self.summary(measurements, failures: failures, stepFailure: stepFailure))
        attachment.name = "summary.txt"
        attachment.lifetime = .keepAlways
        add(attachment)

        if let stepFailure {
            XCTFail("G3 step failed: \(stepFailure)")
        }
        XCTAssertEqual(failures, [], "the G3 conditions that fail")
    }

    /// The steps of the run, in order. A thrown step ends the run, and the caller still stops the boot.
    private func measure(_ session: G3Session, into measurements: inout G3Measurements) async throws {
        try session.installImage()
        session.note("image installed")
        try session.startBoot()
        try await session.waitForReady(timeout: .seconds(600))
        session.note("state: ready")

        // Device preparation, as the manual run did it: the keyguard, the screen timeout, and the GLES renderer.
        let bootCompleted = try session.adb(["shell", "getprop sys.boot_completed"])
        try session.writeArtifact("boot-completed.txt", bootCompleted.output)
        let gles = try session.adb([
            "shell", "getprop ro.hardware.egl; getenforce; dumpsys SurfaceFlinger | grep -i GLES",
        ])
        try session.writeArtifact("gl-props.txt", gles.output)
        measurements.surfaceFlingerGLES = gles.output
        try session.adb(["shell", "input keyevent 82"])
        try session.adb(["shell", "wm dismiss-keyguard"])
        try await Task.sleep(for: .seconds(3))
        let keyguard = try session.adb(["shell", "dumpsys window | grep -i keyguard"])
        try session.writeArtifact("keyguard.txt", keyguard.output)
        try session.adb(["shell", "settings put system screen_off_timeout 2147483647"])
        try session.adb(["shell", "svc power stayon true"])
        session.note("keyguard dismissed, screen timeout off")

        let install = try session.adb(["install", "-r", session.inputs.helloGL.path], timeout: 300)
        try session.writeArtifact("install-hellogl.txt", install.output)
        guard install.status == 0 else {
            throw G3Failure.commandFailed("adb install HelloGL", install.status, install.output)
        }

        // Normal mode: the renderer event, the window, and 60 s of statistics.
        let launchMark = session.lineMark
        try session.adb(["shell", "am start -W -n \(G3Session.activity)"])
        try await Task.sleep(for: .seconds(15))
        let rendererLog = try session.adb(["logcat", "-d", "-s", "HelloGL:V"])
        try session.writeArtifact("renderer-logcat.txt", rendererLog.output)
        measurements.rendererEvent = G3Evidence.rendererEvent(in: rendererLog.output)
        let firstWindow = try session.captureWindow(to: "normal-1.png")
        session.note("window \(firstWindow) captured")
        measurements.windowFound = true
        measurements.distinctColoursInWindow = G3Session.distinctColours(
            inPNG: session.inputs.artifacts.appendingPathComponent("screenshots/normal-1.png"))
        let launchedPID = try session.helloGLPID()
        session.note("HelloGL pid after launch: \(launchedPID ?? "none")")
        guard launchedPID != nil else {
            throw G3Failure.commandFailed("pidof HelloGL", 1, "HelloGL is not running after the launch")
        }

        let sixtyMark = session.lineMark
        try await Task.sleep(for: .seconds(30))
        _ = try session.captureWindow(to: "normal-30s.png")
        try await Task.sleep(for: .seconds(30))
        _ = try session.captureWindow(to: "normal-60s.png")
        measurements.statisticsFirstSixtySeconds = session.statisticsLines(after: sixtyMark)
        try session.writeArtifact("stats-60s.txt", session.rawStatisticsLines(after: sixtyMark))
        session.note("60 s window: \(measurements.statisticsFirstSixtySeconds.count) statistics lines")

        // Alternating-colour phase: the sampler counts the frames of this phase by the change of its counters.
        let alternatingBefore = session.lineMark
        let before = session.lastStatistics(before: alternatingBefore)
        try session.adb([
            "shell", "am start -S -W -n \(G3Session.activity) --ez io.apkrun.fixture.hellogl.ALTERNATE true",
        ])
        try await Task.sleep(for: .seconds(5))
        for index in 1...4 {
            _ = try session.captureWindow(to: "alternating-\(index).png")
            try await Task.sleep(for: .seconds(1))
        }
        let stabMarkLine = session.lineMark
        let after = session.lastStatistics(before: stabMarkLine)
        measurements.alternatingSampledFrames = Self.difference(after?.framesSampled, before?.framesSampled)
        measurements.alternatingRedFrames = Self.difference(after?.redFrames, before?.redFrames)
        measurements.alternatingBlueFrames = Self.difference(after?.blueFrames, before?.blueFrames)
        measurements.alternatingMixedFrames = Self.difference(after?.mixedFrames, before?.mixedFrames)
        measurements.unreadableFrames = session.statisticsLines(after: 0).compactMap(\.unreadable).max() ?? 0
        session.note(
            "alternating phase: sampled \(measurements.alternatingSampledFrames), "
                + "red \(measurements.alternatingRedFrames), blue \(measurements.alternatingBlueFrames), "
                + "mixed \(measurements.alternatingMixedFrames)")

        // Ten minutes in normal mode, with a marker in the guest log that scopes the fps events and the crash lines.
        try session.adb(["shell", "log -t APKRUN-G3 stab-start"])
        try session.adb(["shell", "am start -S -W -n \(G3Session.activity)"])
        try await Task.sleep(for: .seconds(10))
        measurements.pidAtStart = try session.helloGLPID()
        for minute in 1...10 {
            try await Task.sleep(for: .seconds(60))
            let pid = try session.helloGLPID()
            measurements.pidAtMinute.append(pid)
            _ = try session.captureWindow(to: String(format: "stab-%02d.png", minute))
            session.note("minute \(minute): pid \(pid ?? "none")")
        }
        // The statistics of the whole normal run, from its first launch to the end of the 10 minutes.
        measurements.statisticsDuringRun = session.statisticsLines(after: launchMark)
        try session.writeArtifact("stats-run.txt", session.rawStatisticsLines(after: launchMark))
        let pidLines =
            ["start \(measurements.pidAtStart ?? "none")"]
            + measurements.pidAtMinute.enumerated().map { "minute \($0.offset + 1) \($0.element ?? "none")" }
        try session.writeArtifact("pids.txt", pidLines.joined(separator: "\n") + "\n")

        let guest = session.guestLog()
        guard let markerRange = guest.range(of: "APKRUN-G3: stab-start", options: .backwards) else {
            throw G3Failure.commandFailed("guest log", 1, "the stab-start marker is missing from the guest log")
        }
        let afterMarker = String(guest[markerRange.upperBound...])
        measurements.fpsEvents = G3Evidence.fpsEvents(in: afterMarker)
        try session.writeArtifact(
            "stab-fps.txt",
            afterMarker.split(whereSeparator: \.isNewline)
                .filter { $0.contains("APKRUN-FIXTURE") }.joined(separator: "\n") + "\n")
        let crashes = afterMarker.split(whereSeparator: \.isNewline).map(String.init).filter(G3Evidence.isAnyCrash)
        measurements.rendererCrashLines = crashes.filter(G3Evidence.isRendererCrash)
        measurements.otherCrashLines = crashes.count - measurements.rendererCrashLines.count
        try session.writeArtifact("guest-crash-lines.txt", crashes.joined(separator: "\n") + "\n")
        session.note(
            "10 minute run: \(measurements.fpsEvents.count) fps events, "
                + "\(measurements.rendererCrashLines.count) renderer crash lines, "
                + "\(measurements.otherCrashLines) other crash lines")
    }

    private static func difference(_ after: Int?, _ before: Int?) -> Int {
        guard let after, let before else {
            return 0
        }
        return after - before
    }

    private static func summary(
        _ measurements: G3Measurements, failures: [String], stepFailure: Error?
    ) -> String {
        var lines = [
            "gate: G3",
            "step failure: \(stepFailure.map { "\($0)" } ?? "none")",
            "window found: \(measurements.windowFound), distinct colours in the first capture: "
                + "\(measurements.distinctColoursInWindow)",
            "renderer event: \(measurements.rendererEvent ?? "none")",
            "GLES lines: \(measurements.surfaceFlingerGLES.replacingOccurrences(of: "\n", with: " | "))",
            "statistics during the run: \(measurements.statisticsDuringRun.count) lines, "
                + "hostReadbacks max \(measurements.statisticsDuringRun.map(\.hostReadbacks).max() ?? 0), "
                + "cpuPixelCopies max \(measurements.statisticsDuringRun.map(\.cpuPixelCopies).max() ?? 0)",
            "statistics in the first 60 s: \(measurements.statisticsFirstSixtySeconds.count) lines",
            "fps events in the 10 minute run: \(measurements.fpsEvents.count), average "
                + String(
                    format: "%.2f",
                    measurements.fpsEvents.isEmpty
                        ? 0 : measurements.fpsEvents.reduce(0, +) / Double(measurements.fpsEvents.count)),
            "alternating phase: sampled \(measurements.alternatingSampledFrames), red \(measurements.alternatingRedFrames), "
                + "blue \(measurements.alternatingBlueFrames), mixed \(measurements.alternatingMixedFrames)",
            "HelloGL pid at start: \(measurements.pidAtStart ?? "none"), at minutes: "
                + measurements.pidAtMinute.map { $0 ?? "none" }.joined(separator: ","),
            "renderer crash lines: \(measurements.rendererCrashLines.count), other crash lines: \(measurements.otherCrashLines)",
            "boot stop: \(measurements.bootStop.rawValue)",
            "unreadable buffers in the tearing sampler: \(measurements.unreadableFrames)",
        ]
        lines.append(
            contentsOf: failures.isEmpty ? ["result: passed"] : ["result: failed"] + failures.map { "failed: \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }
}
