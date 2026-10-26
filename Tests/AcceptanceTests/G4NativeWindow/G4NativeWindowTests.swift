import AVFoundation
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit
import Vision
import XCTest

/// Gate G4: launch the debug HelloText fixture through the actual `apkrun dev launch` command, then send physical
/// WindowServer events through the native window. Android state is observed with the fixture's logcat diagnostics.
@MainActor
final class G4NativeWindowTests: XCTestCase {
    fileprivate static let package = "io.apkrun.fixture.hellotext"
    fileprivate static let buttonID = "\(package):id/increment_button"
    fileprivate static let fieldID = "\(package):id/input_text"
    fileprivate static let detailsID = "\(package):id/details_button"
    fileprivate static let textAction = "\(package).debug.TEXT"
    fileprivate static let textPrefix = "APKRUN-FIXTURE: text "
    fileprivate static let clickPrefix = "APKRUN-FIXTURE: click "
    fileprivate static let screenPrefix = "APKRUN-FIXTURE: screen "
    fileprivate static let expectedText = "Hello, APKRun 123!"

    override func setUpWithError() throws {
        try super.setUpWithError()
        let environment = ProcessInfo.processInfo.environment
        let selected = environment["APKRUN_ACCEPTANCE_SUITE"] == "g4"
        if environment["APKRUN_G4_REQUIRED"] == "1" {
            guard selected else {
                throw G4Failure.notSelected
            }
            return
        }
        guard selected else {
            throw XCTSkip("The G4 check runs in the G4 test-plan configuration.")
        }
    }

    func testHelloTextLaunchesAndAcceptsHostInputInANativeWindow() async throws {
        executionTimeAllowance = 1_200
        let session = try G4Session(inputs: G4Inputs.fromEnvironment())
        defer { session.removeHome() }

        var clicks: [Int] = []
        var typedText: String?
        var screenAfterEscape: String?
        var shellCountBeforeEvents: Int?
        var shellCountAfterEvents: Int?
        var launchExitCode: Int32?
        var launchTerminationReason: String?
        var windowCapture: String?
        var recording: G4RecordingEvidence?
        var stepFailure: String?

        do {
            try session.requireHostInputAccess()
            try session.installImage()
            try session.startLaunch()
            let window = try await session.waitForHelloTextWindow(timeout: .seconds(600))
            shellCountBeforeEvents = try await session.waitForInputBinding(timeout: .seconds(120))
            let displaySize = try session.displaySize()
            try await session.waitForScreen("main", timeout: .seconds(60))
            try await session.captureVisibleHelloTextWindow(
                window,
                named: "hellotext.png",
                timeout: .seconds(30)
            )
            windowCapture = "screenshots/hellotext.png"
            try await session.startScreenRecording(window: window)
            try await session.clickButtonOneHundredTimes(window: window, displaySize: displaySize)
            clicks = try await session.waitForClicks(Array(1...100), timeout: .seconds(30))

            try await session.click(viewID: Self.detailsID, window: window, displaySize: displaySize)
            try await session.waitForScreen("details", timeout: .seconds(30))
            try session.press(.escape)
            let screens = try await session.waitForScreens(["details", "main"], timeout: .seconds(30))
            screenAfterEscape = screens.last

            try await session.focusField()
            try session.type(Self.expectedText)
            try session.requestFieldText()
            typedText = try await session.waitForFieldText(timeout: .seconds(20))
            try await session.waitForScreenRecordingFrameAfterLastHostInput(timeout: 20)
            let stopped = await session.stopLaunch()
            shellCountAfterEvents = stopped.adbCount
            launchExitCode = stopped.exitCode
            launchTerminationReason = stopped.terminationReason
        } catch {
            stepFailure = String(describing: error)
            let stopped = await session.stopLaunch()
            shellCountAfterEvents = stopped.adbCount
            launchExitCode = stopped.exitCode
            launchTerminationReason = stopped.terminationReason
        }
        recording = await session.finishScreenRecording()

        let failures = Self.failures(
            clicks: clicks,
            typedText: typedText,
            screenAfterEscape: screenAfterEscape,
            shellCountBeforeEvents: shellCountBeforeEvents,
            shellCountAfterEvents: shellCountAfterEvents,
            launchExitCode: launchExitCode,
            launchTerminationReason: launchTerminationReason,
            windowCapture: windowCapture,
            recording: recording,
            stepFailure: stepFailure,
            session: session
        )
        let summary = Self.summary(
            clicks: clicks,
            typedText: typedText,
            screenAfterEscape: screenAfterEscape,
            shellCountBeforeEvents: shellCountBeforeEvents,
            shellCountAfterEvents: shellCountAfterEvents,
            launchExitCode: launchExitCode,
            launchTerminationReason: launchTerminationReason,
            windowCapture: windowCapture,
            recording: recording,
            failures: failures
        )
        try session.writeSummary(
            clicks: clicks,
            typedText: typedText,
            screenAfterEscape: screenAfterEscape,
            shellCountBeforeEvents: shellCountBeforeEvents,
            shellCountAfterEvents: shellCountAfterEvents,
            launchExitCode: launchExitCode,
            launchTerminationReason: launchTerminationReason,
            windowCapture: windowCapture,
            recording: recording,
            failures: failures
        )
        let attachment = XCTAttachment(string: summary)
        attachment.name = "G4 summary"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(failures, [], "G4 conditions that failed")
    }

    private static func failures(
        clicks: [Int],
        typedText: String?,
        screenAfterEscape: String?,
        shellCountBeforeEvents: Int?,
        shellCountAfterEvents: Int?,
        launchExitCode: Int32?,
        launchTerminationReason: String?,
        windowCapture: String?,
        recording: G4RecordingEvidence?,
        stepFailure: String?,
        session: G4Session
    ) -> [String] {
        var result: [String] = []
        if let stepFailure {
            result.append("step failed: \(stepFailure)")
        }
        if clicks != Array(1...100) {
            result.append("HelloText logged \(clicks.count) of 100 sequential button clicks")
        }
        if typedText != expectedText {
            result.append("the text field contained \(typedText.map { String(reflecting: $0) } ?? "no value")")
        }
        if screenAfterEscape != "main" {
            result.append("Escape ended on \(screenAfterEscape ?? "no screen") instead of screen main")
        }
        if launchExitCode != 130 || launchTerminationReason != "exit" {
            result.append(
                "apkrun dev launch did not exit normally after the handled interrupt "
                    + "(status \(launchExitCode.map(String.init) ?? "unavailable"), "
                    + "reason \(launchTerminationReason ?? "unavailable"))"
            )
        }
        if shellCountBeforeEvents == nil || shellCountAfterEvents == nil {
            result.append("the ADB shell invocation count was not available at both boundaries")
        } else if shellCountBeforeEvents != shellCountAfterEvents {
            result.append(
                "ADB shell invocations changed from \(shellCountBeforeEvents!) to \(shellCountAfterEvents!) "
                    + "during host input")
        }
        if windowCapture == nil || !session.hasArtifact("screenshots/hellotext.png") {
            result.append("the HelloText window screenshot is missing")
        }
        guard let recording else {
            result.append("the synchronized screen recording did not finish")
            return result
        }
        if recording.movieBytes <= 0 {
            result.append("the screen recording is missing or empty")
        }
        if !recording.finishedSuccessfully {
            result.append("ScreenCaptureKit did not finish writing the recording")
        }
        if let failure = recording.failure {
            result.append("screen recording failed: \(failure)")
        }
        if recording.videoTrackCount == 0 || recording.durationMilliseconds <= 0 {
            result.append("the completed movie has no readable video track or positive duration")
        }
        if recording.frameCount == 0 {
            result.append("ScreenCaptureKit did not deliver a recorded video frame")
        }
        if recording.hostInputEventCount == 0
            || recording.recordedHostInputEventCount != recording.hostInputEventCount
        {
            result.append(
                "ScreenCaptureKit recorded \(recording.recordedHostInputEventCount) of "
                    + "\(recording.hostInputEventCount) host input events")
        }
        if !recording.startedBeforeFirstHostEvent {
            result.append("the recording output did not start before the first host input event")
        }
        if !recording.framesBracketHostInput {
            result.append("captured video frames do not bracket every host input event")
        }
        return result
    }

    fileprivate static func summary(
        clicks: [Int],
        typedText: String?,
        screenAfterEscape: String?,
        shellCountBeforeEvents: Int?,
        shellCountAfterEvents: Int?,
        launchExitCode: Int32?,
        launchTerminationReason: String?,
        windowCapture: String?,
        recording: G4RecordingEvidence?,
        failures: [String]
    ) -> String {
        ([
            "gate: G4",
            "command: apkrun dev launch <HelloText-debug.apk>",
            "native_window_title: HelloText",
            "window_capture: \(windowCapture ?? "missing")",
            "clicks_observed: \(clicks.count)",
            "click_sequence: \(clicks == Array(1...100) ? "1..100" : "invalid")",
            "typed_text: \(typedText.map { String(reflecting: $0) } ?? "unavailable")",
            "screen_after_escape: \(screenAfterEscape ?? "unavailable")",
            "adb_shell_count_before_events: \(shellCountBeforeEvents.map(String.init) ?? "unavailable")",
            "adb_shell_count_after_events: \(shellCountAfterEvents.map(String.init) ?? "unavailable")",
            "apkrun_exit_code: \(launchExitCode.map(String.init) ?? "unavailable")",
            "apkrun_termination_reason: \(launchTerminationReason ?? "unavailable")",
            "screen_recording: \(recording?.path ?? "missing")",
            "screen_recording_bytes: \(recording?.movieBytes ?? 0)",
            "screen_recording_finished_successfully: \(recording?.finishedSuccessfully ?? false)",
            "screen_recording_video_tracks: \(recording?.videoTrackCount ?? 0)",
            "screen_recording_duration_ms: \(recording?.durationMilliseconds ?? 0)",
            "screen_recording_frame_count: \(recording?.frameCount ?? 0)",
            "screen_recording_covered_host_input_events: "
                + "\(recording?.recordedHostInputEventCount ?? 0)/\(recording?.hostInputEventCount ?? 0)",
            "screen_recording_started_before_first_host_event: "
                + "\(recording?.startedBeforeFirstHostEvent ?? false)",
            "screen_recording_first_frame_offset_ms: "
                + "\(recording?.firstFrameOffsetMilliseconds.map(String.init) ?? "unavailable")",
            "screen_recording_first_host_input_offset_ms: "
                + "\(recording?.firstHostEventOffsetMilliseconds.map(String.init) ?? "unavailable")",
            "screen_recording_last_host_input_offset_ms: "
                + "\(recording?.lastHostEventOffsetMilliseconds.map(String.init) ?? "unavailable")",
            "screen_recording_last_frame_offset_ms: "
                + "\(recording?.lastFrameOffsetMilliseconds.map(String.init) ?? "unavailable")",
            "screen_recording_frames_bracket_host_input: \(recording?.framesBracketHostInput ?? false)",
            "result: \(failures.isEmpty ? "passed" : "failed")",
        ] + failures.map { "failure: \($0)" })
        .joined(separator: "\n") + "\n"
    }
}

private struct G4RecordingEvidence {
    let path: String
    let movieBytes: Int
    let finishedSuccessfully: Bool
    let failure: String?
    let videoTrackCount: Int
    let durationMilliseconds: Int
    let frameCount: Int
    let hostInputEventCount: Int
    let recordedHostInputEventCount: Int
    let startedBeforeFirstHostEvent: Bool
    let firstFrameOffsetMilliseconds: Int?
    let firstHostEventOffsetMilliseconds: Int?
    let lastHostEventOffsetMilliseconds: Int?
    let lastFrameOffsetMilliseconds: Int?
    let framesBracketHostInput: Bool
}

private final class G4ScreenCaptureEvidence: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput,
    @unchecked Sendable
{
    private enum WaitCondition: Sendable {
        case recordingStarted
        case frameAfterLastHostInput
        case recordingFinished
    }

    struct Snapshot {
        let failure: String?
        let recordingStartedMachTime: UInt64?
        let finishedSuccessfully: Bool
        let frameCount: Int
        let firstFrameMachTime: UInt64?
        let lastFrameMachTime: UInt64?
        let recordedHostInputEventCount: Int
        let firstHostInputPostStartedMachTime: UInt64?
        let lastHostInputPostCompletedMachTime: UInt64?
    }

    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var failure: String?
    private var recordingStartedMachTime: UInt64?
    private var finishedSuccessfully = false
    private var frameCount = 0
    private var firstFrameMachTime: UInt64?
    private var lastFrameMachTime: UInt64?
    private var recordedHostInputEventCount = 0
    private var firstHostInputPostStartedMachTime: UInt64?
    private var lastHostInputPostCompletedMachTime: UInt64?

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock()
        if recordingStartedMachTime == nil {
            recordingStartedMachTime = mach_absolute_time()
        }
        lock.unlock()
        changed.signal()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        recordFailure(String(describing: error))
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        lock.lock()
        finishedSuccessfully = failure == nil
        lock.unlock()
        changed.signal()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordFailure("the capture stream stopped with an error: \(error)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
            let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
            CVPixelBufferGetWidth(imageBuffer) > 0,
            CVPixelBufferGetHeight(imageBuffer) > 0,
            let attachmentArray = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let attachment = attachmentArray.first,
            let statusValue = attachment[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusValue),
            status == .started || status == .complete,
            let displayTime = attachment[.displayTime] as? NSNumber
        else {
            return
        }
        recordFrame(at: displayTime.uint64Value)
    }

    func recordHostInput(postStartedAt: UInt64, postCompletedAt: UInt64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil, recordingStartedMachTime != nil else {
            throw G4Failure.screenRecordingFailed(failure ?? "input arrived before recording started")
        }
        guard postCompletedAt >= postStartedAt else {
            throw G4Failure.screenRecordingFailed("host input post timestamps are out of order")
        }
        recordedHostInputEventCount += 1
        if firstHostInputPostStartedMachTime == nil {
            firstHostInputPostStartedMachTime = postStartedAt
        }
        lastHostInputPostCompletedMachTime = postCompletedAt
        changed.signal()
    }

    func waitForRecordingStart(timeout: TimeInterval) async throws {
        try await waitFor(.recordingStarted, timeout: timeout)
    }

    func waitForFrameAfterLastHostInput(timeout: TimeInterval) async throws {
        try await waitFor(.frameAfterLastHostInput, timeout: timeout)
    }

    func waitForRecordingFinish(timeout: TimeInterval) async throws {
        try await waitFor(.recordingFinished, timeout: timeout)
    }

    func recordFailure(_ message: String) {
        lock.lock()
        if failure == nil {
            failure = message
        }
        lock.unlock()
        changed.signal()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            failure: failure,
            recordingStartedMachTime: recordingStartedMachTime,
            finishedSuccessfully: finishedSuccessfully,
            frameCount: frameCount,
            firstFrameMachTime: firstFrameMachTime,
            lastFrameMachTime: lastFrameMachTime,
            recordedHostInputEventCount: recordedHostInputEventCount,
            firstHostInputPostStartedMachTime: firstHostInputPostStartedMachTime,
            lastHostInputPostCompletedMachTime: lastHostInputPostCompletedMachTime
        )
    }

    private func recordFrame(at machTime: UInt64) {
        lock.lock()
        frameCount += 1
        if firstFrameMachTime == nil || machTime < firstFrameMachTime! {
            firstFrameMachTime = machTime
        }
        if lastFrameMachTime == nil || machTime > lastFrameMachTime! {
            lastFrameMachTime = machTime
        }
        lock.unlock()
        changed.signal()
    }

    private func waitFor(_ condition: WaitCondition, timeout: TimeInterval) async throws {
        try await Task.detached(priority: .userInitiated) {
            try self.waitSynchronously(for: condition, timeout: timeout)
        }.value
    }

    private func waitSynchronously(for condition: WaitCondition, timeout: TimeInterval) throws {
        let deadline = DispatchTime.now() + timeout
        while true {
            let state = snapshot()
            if let failure = state.failure {
                throw G4Failure.screenRecordingFailed(failure)
            }
            switch condition {
            case .recordingStarted where state.recordingStartedMachTime != nil:
                return
            case .frameAfterLastHostInput:
                if let lastFrame = state.lastFrameMachTime,
                    let lastInput = state.lastHostInputPostCompletedMachTime,
                    lastFrame > lastInput
                {
                    return
                }
            case .recordingFinished where state.finishedSuccessfully:
                return
            default:
                break
            }
            guard changed.wait(timeout: deadline) == .success else {
                let finalState = snapshot()
                if let failure = finalState.failure {
                    throw G4Failure.screenRecordingFailed(failure)
                }
                throw G4Failure.screenRecordingFailed("timed out waiting for \(condition)")
            }
        }
    }
}

private struct G4Inputs {
    let cli: URL
    let bundle: URL
    let helloTextAPK: URL
    let guestDirectory: URL
    let virglRuntime: URL
    let androidHome: URL
    let artifacts: URL

    static func fromEnvironment() throws -> G4Inputs {
        let environment = ProcessInfo.processInfo.environment
        func path(_ key: String) throws -> URL {
            let fromInfo = Bundle.main.object(forInfoDictionaryKey: key) as? String
            guard let value = environment[key] ?? fromInfo, !value.isEmpty, value.hasPrefix("/") else {
                throw G4Failure.missingInput(key)
            }
            return URL(fileURLWithPath: value)
        }
        return G4Inputs(
            cli: try path("APKRUN_G4_CLI"),
            bundle: try path("APKRUN_G4_BUNDLE"),
            helloTextAPK: try path("APKRUN_G4_APK"),
            guestDirectory: try path("APKRUN_G4_GUEST_DIR"),
            virglRuntime: try path("APKRUN_G4_VIRGL_RUNTIME"),
            androidHome: try path("APKRUN_G4_ANDROID_HOME"),
            artifacts: try path("APKRUN_G4_ARTIFACTS")
        )
    }
}

private enum G4Failure: Error, CustomStringConvertible {
    case notSelected
    case missingInput(String)
    case commandFailed(String, Int32, String)
    case commandTimedOut(String)
    case launchEnded(String)
    case noWindow(String)
    case windowContentNotVisible(String)
    case runnerMissingPermission(String)
    case eventCouldNotBeCreated
    case screenRecordingFailed(String)
    case screenRecordingStoppedDuringInput
    case viewNotFound(String)
    case malformedOutput(String)

    var description: String {
        switch self {
        case .notSelected:
            "The G4 configuration did not set APKRUN_ACCEPTANCE_SUITE=g4."
        case .missingInput(let key):
            "\(key) is not set to an absolute path. scripts/run-gate.sh G4 sets it."
        case .commandFailed(let command, let status, let output):
            "\(command) exited with \(status): \(output.suffix(400))"
        case .commandTimedOut(let command):
            "\(command) did not finish in time"
        case .launchEnded(let output):
            "apkrun dev launch ended before the check finished: \(output.suffix(600))"
        case .noWindow(let detail):
            detail
        case .windowContentNotVisible(let detail):
            detail
        case .runnerMissingPermission(let permission):
            "APKRunTestHost is missing \(permission) permission. Grant it to this exact test host in System Settings, "
                + "then rerun scripts/run-gate.sh G4. The test does not request access."
        case .eventCouldNotBeCreated:
            "macOS did not create a host mouse or keyboard event."
        case .screenRecordingFailed(let detail):
            "could not record the G4 native-window interactions: \(detail)"
        case .screenRecordingStoppedDuringInput:
            "ScreenCaptureKit stopped while G4 was posting host input events"
        case .viewNotFound(let identifier):
            "HelloText did not expose \(identifier) in the UI hierarchy."
        case .malformedOutput(let detail):
            detail
        }
    }
}

@MainActor
private final class G4Session {
    private static let adbCountPrefix = "ADB shell invocations so far: "
    private static let windowTitle = "HelloText"
    private static let screenRecordingDurationSeconds = 120
    private static let screenRecordingStartTimeout: TimeInterval = 30
    private static let screenRecordingFinishTimeout: TimeInterval = 15
    private let inputs: G4Inputs
    let home: URL
    private var launch: Process?
    private var launchOutputFile: FileHandle?
    private let launchOutputURL: URL
    private var adbLogNumber = 0
    private var screenStream: SCStream?
    private var screenRecordingOutput: SCRecordingOutput?
    private var screenCaptureEvidence: G4ScreenCaptureEvidence?
    private var screenRecordingLimitTask: Task<Void, Never>?
    private let screenRecordingURL: URL
    private var screenRecordingStartMachTime: UInt64?
    private var hostInputEventCount = 0
    private var recordedHostInputEventCount = 0

    init(inputs: G4Inputs) throws {
        self.inputs = inputs
        home = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "apkrun-g4-\(UUID().uuidString.prefix(8).lowercased())", isDirectory: true)
        launchOutputURL = inputs.artifacts.appendingPathComponent("apkrun-dev-launch.log")
        screenRecordingURL = inputs.artifacts.appendingPathComponent("screen-recording.mov")
        try FileManager.default.createDirectory(at: inputs.artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private var childEnvironment: [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["USER", "LANG", "TMPDIR"] {
            environment[key] = inherited[key]
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOME"] = inherited["HOME"]
        environment["APKRUN_HOME"] = home.path
        environment["APKRUN_GUEST_DIR"] = inputs.guestDirectory.path
        environment["APKRUN_VIRGL_RUNTIME_PATH"] = inputs.virglRuntime.path
        environment["ANDROID_HOME"] = inputs.androidHome.path
        return environment
    }

    func requireHostInputAccess() throws {
        guard CGPreflightPostEventAccess() else {
            throw G4Failure.runnerMissingPermission("Device Control and Data Access")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw G4Failure.runnerMissingPermission("Screen Recording")
        }
    }

    func installImage() throws {
        let result = try runCLI(["dev", "image", "install", inputs.bundle.path], timeout: 900)
        try writeArtifact("install-image.log", result.output)
        guard result.status == 0 else {
            throw G4Failure.commandFailed("apkrun dev image install", result.status, result.output)
        }
    }

    func startLaunch() throws {
        let process = Process()
        process.executableURL = inputs.cli
        process.arguments = ["dev", "launch", inputs.helloTextAPK.path]
        process.environment = childEnvironment
        guard FileManager.default.createFile(atPath: launchOutputURL.path, contents: nil) else {
            throw G4Failure.commandFailed("create \(launchOutputURL.lastPathComponent)", 1, "")
        }
        let file = try FileHandle(forWritingTo: launchOutputURL)
        process.standardOutput = file
        process.standardError = file
        try process.run()
        launch = process
        launchOutputFile = file
    }

    func waitForHelloTextWindow(timeout: Duration) async throws -> G4Window {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let launch, !launch.isRunning {
                throw G4Failure.launchEnded(launchOutput())
            }
            let window = Self.windows(onScreenOnly: true).first {
                $0.owner == launch?.processIdentifier && $0.title == Self.windowTitle
            }
            if let window {
                guard let app = launch.flatMap({ NSRunningApplication(processIdentifier: $0.processIdentifier) }) else {
                    throw G4Failure.noWindow("the `apkrun dev launch` process disappeared after its window opened")
                }
                _ = app.activate(options: [])
                while ContinuousClock.now < deadline {
                    if app.isActive {
                        return window
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw G4Failure.noWindow(
            "no on-screen window titled HelloText belongs to the `apkrun dev launch` process; "
                + "CLI output: \(launchOutput().suffix(600))")
    }

    func waitForInputBinding(timeout: Duration) async throws -> Int {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let lines = launchOutput().split(whereSeparator: \.isNewline).map(String.init)
            if let bindIndex = lines.lastIndex(where: { $0.contains("input is bound to display") }),
                let count = lines.dropFirst(bindIndex + 1).compactMap(Self.adbCount(in:)).first
            {
                return count
            }
            if let launch, !launch.isRunning {
                throw G4Failure.launchEnded(launchOutput())
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw G4Failure.malformedOutput("the CLI did not report that its Guest Agent input route was bound")
    }

    func displaySize() throws -> G4DisplaySize {
        let result = try runCLI(["dev", "adb", "shell", "wm", "size", "-d", "0"], timeout: 30)
        guard result.status == 0,
            let match = Self.firstMatch(#"(?:Physical|Override) size:\s*(\d+)x(\d+)"#, in: result.output),
            let width = Int(match[1]),
            let height = Int(match[2]),
            width > 0,
            height > 0
        else {
            throw G4Failure.malformedOutput("could not read display 0 geometry from `wm size`: \(result.output)")
        }
        return G4DisplaySize(width: width, height: height)
    }

    func captureWindow(_ window: G4Window, named name: String) throws {
        let destination = screenshotURL(named: name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let result = try runProcess(
            URL(fileURLWithPath: "/usr/sbin/screencapture"),
            ["-x", "-o", "-l", String(window.number), destination.path],
            timeout: 30
        )
        guard result.status == 0, hasArtifact("screenshots/\(name)") else {
            throw G4Failure.commandFailed("screencapture HelloText", result.status, result.output)
        }
    }

    func captureVisibleHelloTextWindow(_ window: G4Window, named name: String, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        let screenshot = screenshotURL(named: name)
        var recognizedText: [String] = []
        while ContinuousClock.now < deadline {
            try captureWindow(window, named: name)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(url: screenshot).perform([request])
            recognizedText = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
            if recognizedText.contains(where: { $0.localizedCaseInsensitiveContains("Increment") }) {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw G4Failure.windowContentNotVisible(
            "the native-window screenshot did not show HelloText's Increment button; "
                + "Vision saw [\(recognizedText.joined(separator: " | "))]"
        )
    }

    private func screenshotURL(named name: String) -> URL {
        inputs.artifacts.appendingPathComponent("screenshots", isDirectory: true)
            .appendingPathComponent(name)
    }

    func startScreenRecording(window targetWindow: G4Window) async throws {
        let shareableContent = try await SCShareableContent.current
        guard let window = shareableContent.windows.first(where: { $0.windowID == CGWindowID(targetWindow.number) })
        else {
            throw G4Failure.screenRecordingFailed("the HelloText native window is not available to ScreenCaptureKit")
        }
        if FileManager.default.fileExists(atPath: screenRecordingURL.path) {
            try FileManager.default.removeItem(at: screenRecordingURL)
        }

        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(window.frame.width.rounded(.up)))
        configuration.height = max(2, Int(window.frame.height.rounded(.up)))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = screenRecordingURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264

        let evidence = G4ScreenCaptureEvidence()
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: evidence)
        let stream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration,
            delegate: evidence
        )
        let outputQueue = DispatchQueue(label: "io.apkrun.acceptance.g4-screen-capture", qos: .userInitiated)
        do {
            try stream.addStreamOutput(evidence, type: .screen, sampleHandlerQueue: outputQueue)
            try stream.addRecordingOutput(output)
            screenCaptureEvidence = evidence
            screenRecordingOutput = output
            screenStream = stream
            screenRecordingStartMachTime = mach_absolute_time()
            try await stream.startCapture()
            try await evidence.waitForRecordingStart(timeout: Self.screenRecordingStartTimeout)
            screenRecordingLimitTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.screenRecordingDurationSeconds))
                } catch {
                    return
                }
                await self?.stopRecordingAtDurationLimit()
            }
        } catch {
            evidence.recordFailure(String(describing: error))
            throw G4Failure.screenRecordingFailed(String(describing: error))
        }
    }

    func waitForScreenRecordingFrameAfterLastHostInput(timeout: TimeInterval) async throws {
        guard let screenCaptureEvidence else {
            throw G4Failure.screenRecordingFailed("screen capture was not started")
        }
        try await screenCaptureEvidence.waitForFrameAfterLastHostInput(timeout: timeout)
    }

    func finishScreenRecording() async -> G4RecordingEvidence {
        screenRecordingLimitTask?.cancel()
        screenRecordingLimitTask = nil
        let evidence = screenCaptureEvidence
        if let screenStream {
            do {
                try await screenStream.stopCapture()
            } catch {
                evidence?.recordFailure("could not stop the capture stream: \(error)")
            }
        }
        if let evidence {
            do {
                try await evidence.waitForRecordingFinish(timeout: Self.screenRecordingFinishTimeout)
            } catch {
                evidence.recordFailure(String(describing: error))
            }
        }

        var failure = evidence?.snapshot().failure
        var videoTrackCount = 0
        var durationMilliseconds = 0
        if evidence?.snapshot().finishedSuccessfully == true {
            do {
                let movie = AVURLAsset(url: screenRecordingURL)
                videoTrackCount = try await movie.load(.tracks).filter { $0.mediaType == .video }.count
                let duration = try await movie.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite, seconds > 0 {
                    durationMilliseconds = Int(seconds * 1_000)
                }
            } catch {
                failure = "the completed movie could not be read: \(error)"
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: screenRecordingURL.path)
        let movieBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let state = evidence?.snapshot()
        let origin = screenRecordingStartMachTime
        let firstFrame = state?.firstFrameMachTime
        let lastFrame = state?.lastFrameMachTime
        func milliseconds(from tick: UInt64?) -> Int? {
            guard let tick, let origin, tick >= origin else {
                return nil
            }
            var timebase = mach_timebase_info_data_t()
            guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else {
                return nil
            }
            let nanoseconds = Double(tick - origin) * Double(timebase.numer) / Double(timebase.denom)
            return Int(nanoseconds / 1_000_000)
        }
        let firstInput = state?.firstHostInputPostStartedMachTime
        let lastInput = state?.lastHostInputPostCompletedMachTime
        let startedBeforeFirstHostEvent =
            state?.recordingStartedMachTime.map { startTime in
                guard let firstInput else {
                    return false
                }
                return startTime <= firstInput
            } ?? false
        let framesBracketHostInput: Bool
        if let firstFrame, let firstInput, let lastInput, let lastFrame {
            framesBracketHostInput = firstFrame <= firstInput && lastInput <= lastFrame
        } else {
            framesBracketHostInput = false
        }
        return G4RecordingEvidence(
            path: "screen-recording.mov",
            movieBytes: movieBytes,
            finishedSuccessfully: state?.finishedSuccessfully == true && failure == nil,
            failure: failure,
            videoTrackCount: videoTrackCount,
            durationMilliseconds: durationMilliseconds,
            frameCount: state?.frameCount ?? 0,
            hostInputEventCount: hostInputEventCount,
            recordedHostInputEventCount: state?.recordedHostInputEventCount ?? 0,
            startedBeforeFirstHostEvent: startedBeforeFirstHostEvent,
            firstFrameOffsetMilliseconds: milliseconds(from: firstFrame),
            firstHostEventOffsetMilliseconds: milliseconds(from: firstInput),
            lastHostEventOffsetMilliseconds: milliseconds(from: lastInput),
            lastFrameOffsetMilliseconds: milliseconds(from: lastFrame),
            framesBracketHostInput: framesBracketHostInput
        )
    }

    private func stopRecordingAtDurationLimit() async {
        screenCaptureEvidence?.recordFailure(
            "recording exceeded the \(Self.screenRecordingDurationSeconds)-second limit"
        )
        do {
            try await screenStream?.stopCapture()
        } catch {
            screenCaptureEvidence?.recordFailure("could not stop the capture stream at its duration limit: \(error)")
        }
    }

    func waitForScreen(_ screen: String, timeout: Duration) async throws {
        _ = try await waitForFixtureLog(timeout: timeout) { lines in
            lines.contains { $0.contains(G4NativeWindowTests.screenPrefix + screen) }
        }
    }

    func waitForScreens(_ expected: [String], timeout: Duration) async throws -> [String] {
        let output = try await waitForFixtureLog(timeout: timeout) { lines in
            let screens = Self.screenNames(in: lines)
            guard screens.count >= expected.count else {
                return false
            }
            return Array(screens.suffix(expected.count)) == expected
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        return Array(Self.screenNames(in: lines).suffix(expected.count))
    }

    func clickButtonOneHundredTimes(window: G4Window, displaySize: G4DisplaySize) async throws {
        let bounds = try await viewBounds(G4NativeWindowTests.buttonID)
        for _ in 1...100 {
            try postClick(
                in: bounds.center,
                window: window,
                displaySize: displaySize
            )
            try await Task.sleep(for: .milliseconds(35))
        }
    }

    func click(viewID: String, window: G4Window, displaySize: G4DisplaySize) async throws {
        let bounds = try await viewBounds(viewID)
        try postClick(in: bounds.center, window: window, displaySize: displaySize)
    }

    func focusField() async throws {
        for _ in 0..<8 {
            let view = try await viewInfo(G4NativeWindowTests.fieldID)
            if view.focused {
                return
            }
            try press(.tab)
            try await Task.sleep(for: .milliseconds(100))
        }
        let view = try await viewInfo(G4NativeWindowTests.fieldID)
        guard view.focused else {
            throw G4Failure.viewNotFound("focused \(G4NativeWindowTests.fieldID)")
        }
    }

    func type(_ text: String) throws {
        for character in text {
            guard let key = G4USKey.typing(character) else {
                throw G4Failure.malformedOutput("the G4 US key map does not cover \(character)")
            }
            try press(key)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func press(_ key: G4USKey) throws {
        if key.shift {
            try postKey(.flagsChanged, code: 0x38, shift: true)
        }
        try postKey(.keyDown, code: key.code, shift: key.shift)
        try postKey(.keyUp, code: key.code, shift: key.shift)
        if key.shift {
            try postKey(.flagsChanged, code: 0x38, shift: false)
        }
    }

    func requestFieldText() throws {
        let result = try runCLI(
            [
                "dev", "adb", "shell", "am", "broadcast", "-a", G4NativeWindowTests.textAction, "-p",
                G4NativeWindowTests.package,
            ], timeout: 30)
        guard result.status == 0 else {
            throw G4Failure.commandFailed("HelloText TEXT broadcast", result.status, result.output)
        }
        try writeArtifact("text-query.log", result.output)
    }

    func waitForFieldText(timeout: Duration) async throws -> String {
        let output = try await waitForFixtureLog(timeout: timeout) { lines in
            lines.contains { $0.contains(G4NativeWindowTests.textPrefix) }
        }
        guard
            let line = output.split(whereSeparator: \.isNewline)
                .last(where: { $0.contains(G4NativeWindowTests.textPrefix) }),
            let marker = line.range(of: G4NativeWindowTests.textPrefix)
        else {
            throw G4Failure.malformedOutput("HelloText did not report the text field value")
        }
        let json = String(line[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONDecoder().decode(String.self, from: Data(json.utf8))
    }

    func waitForClicks(_ expected: [Int], timeout: Duration) async throws -> [Int] {
        let output = try await waitForFixtureLog(timeout: timeout) { lines in
            Self.clickNumbers(in: lines).count >= expected.count
        }
        return Self.clickNumbers(in: output.split(whereSeparator: \.isNewline).map(String.init))
    }

    func stopLaunch() async -> (exitCode: Int32?, terminationReason: String?, adbCount: Int?) {
        guard let launch else {
            let lines = launchOutput().split(whereSeparator: \.isNewline).map(String.init)
            return (nil, nil, lines.reversed().compactMap(Self.adbCount(in:)).first)
        }
        if launch.isRunning {
            launch.interrupt()
            let deadline = ContinuousClock.now + .seconds(60)
            while launch.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        if launch.isRunning {
            kill(launch.processIdentifier, SIGKILL)
            while launch.isRunning {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        try? launchOutputFile?.close()
        launchOutputFile = nil
        let lines = launchOutput().split(whereSeparator: \.isNewline).map(String.init)
        let reason: String
        switch launch.terminationReason {
        case .exit:
            reason = "exit"
        case .uncaughtSignal:
            reason = "uncaughtSignal"
        @unknown default:
            reason = "unknown"
        }
        return (launch.terminationStatus, reason, lines.reversed().compactMap(Self.adbCount(in:)).first)
    }

    func removeHome() {
        VMRunResources.removeHomeOrReport(home)
    }

    func hasArtifact(_ path: String) -> Bool {
        let url = inputs.artifacts.appendingPathComponent(path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }

    func writeSummary(
        clicks: [Int],
        typedText: String?,
        screenAfterEscape: String?,
        shellCountBeforeEvents: Int?,
        shellCountAfterEvents: Int?,
        launchExitCode: Int32?,
        launchTerminationReason: String?,
        windowCapture: String?,
        recording: G4RecordingEvidence?,
        failures: [String]
    ) throws {
        let values: [String: Any] = [
            "gate": "G4",
            "result": failures.isEmpty ? "passed" : "failed",
            "command": ["apkrun", "dev", "launch", "<HelloText-debug.apk>"],
            "native_window_title": Self.windowTitle,
            "window_capture": windowCapture.map { $0 as Any } ?? NSNull(),
            "clicks_observed": clicks.count,
            "click_sequence_valid": clicks == Array(1...100),
            "typed_text": typedText.map { $0 as Any } ?? NSNull(),
            "screen_after_escape": screenAfterEscape.map { $0 as Any } ?? NSNull(),
            "adb_shell_count_before_events": shellCountBeforeEvents.map { $0 as Any } ?? NSNull(),
            "adb_shell_count_after_events": shellCountAfterEvents.map { $0 as Any } ?? NSNull(),
            "apkrun_exit_code": launchExitCode.map { $0 as Any } ?? NSNull(),
            "apkrun_termination_reason": launchTerminationReason.map { $0 as Any } ?? NSNull(),
            "screen_recording": recording?.path as Any? ?? NSNull(),
            "screen_recording_bytes": recording?.movieBytes ?? 0,
            "screen_recording_finished_successfully": recording?.finishedSuccessfully ?? false,
            "screen_recording_failure": recording?.failure.map { $0 as Any } ?? NSNull(),
            "screen_recording_video_track_count": recording?.videoTrackCount ?? 0,
            "screen_recording_duration_ms": recording?.durationMilliseconds ?? 0,
            "screen_recording_frame_count": recording?.frameCount ?? 0,
            "host_input_event_count": recording?.hostInputEventCount ?? 0,
            "recorded_host_input_event_count": recording?.recordedHostInputEventCount ?? 0,
            "screen_recording_started_before_first_host_event": recording?.startedBeforeFirstHostEvent ?? false,
            "screen_recording_first_frame_offset_ms": recording?.firstFrameOffsetMilliseconds as Any? ?? NSNull(),
            "first_host_input_offset_ms": recording?.firstHostEventOffsetMilliseconds as Any? ?? NSNull(),
            "last_host_input_offset_ms": recording?.lastHostEventOffsetMilliseconds as Any? ?? NSNull(),
            "screen_recording_last_frame_offset_ms": recording?.lastFrameOffsetMilliseconds as Any? ?? NSNull(),
            "screen_recording_frames_bracket_host_input": recording?.framesBracketHostInput ?? false,
            "failures": failures,
        ]
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: inputs.artifacts.appendingPathComponent("summary.json"), options: .atomic)
        try G4NativeWindowTests.summary(
            clicks: clicks,
            typedText: typedText,
            screenAfterEscape: screenAfterEscape,
            shellCountBeforeEvents: shellCountBeforeEvents,
            shellCountAfterEvents: shellCountAfterEvents,
            launchExitCode: launchExitCode,
            launchTerminationReason: launchTerminationReason,
            windowCapture: windowCapture,
            recording: recording,
            failures: failures
        )
        .write(
            to: inputs.artifacts.appendingPathComponent("summary.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func waitForFixtureLog(
        timeout: Duration,
        matching predicate: ([String]) -> Bool
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        var lastOutput = ""
        while ContinuousClock.now < deadline {
            let result = try runCLI(
                ["dev", "adb", "shell", "logcat", "-d", "-s", "APKRUN-FIXTURE"],
                timeout: 30
            )
            guard result.status == 0 else {
                throw G4Failure.commandFailed("read HelloText fixture log", result.status, result.output)
            }
            lastOutput = result.output
            if predicate(result.output.split(whereSeparator: \.isNewline).map(String.init)) {
                return result.output
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw G4Failure.malformedOutput("timed out waiting for a HelloText marker: \(lastOutput.suffix(500))")
    }

    private func viewBounds(_ identifier: String) async throws -> G4PixelRect {
        try await viewInfo(identifier).bounds
    }

    private func viewInfo(_ identifier: String) async throws -> G4ViewInfo {
        let path = "/sdcard/apkrun-g4-window.xml"
        let dump = try runCLI(["dev", "adb", "shell", "uiautomator", "dump", path], timeout: 60)
        guard dump.status == 0 else {
            throw G4Failure.commandFailed("dump HelloText view hierarchy", dump.status, dump.output)
        }
        let hierarchy = try runCLI(["dev", "adb", "shell", "cat", path], timeout: 30)
        guard hierarchy.status == 0 else {
            throw G4Failure.commandFailed("read HelloText view hierarchy", hierarchy.status, hierarchy.output)
        }
        let escapedID = NSRegularExpression.escapedPattern(for: identifier)
        let elementPattern = "<node\\b(?=[^>]*\\bresource-id=\"\(escapedID)\")[^>]*>"
        guard
            let elementMatch = Self.firstMatch(
                elementPattern,
                in: hierarchy.output,
                options: [.dotMatchesLineSeparators]
            ),
            let boundsMatch = Self.firstMatch(
                #"bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]""#,
                in: elementMatch.whole
            ),
            let left = Double(boundsMatch[1]),
            let top = Double(boundsMatch[2]),
            let right = Double(boundsMatch[3]),
            let bottom = Double(boundsMatch[4])
        else {
            throw G4Failure.viewNotFound(identifier)
        }
        return G4ViewInfo(
            bounds: G4PixelRect(left: left, top: top, right: right, bottom: bottom),
            focused: elementMatch.whole.contains(#"focused="true""#)
        )
    }

    private func postClick(in pixel: CGPoint, window: G4Window, displaySize: G4DisplaySize) throws {
        let location = window.point(for: pixel, displaySize: displaySize)
        guard
            let down = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: location,
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseUp,
                mouseCursorPosition: location,
                mouseButton: .left
            )
        else {
            throw G4Failure.eventCouldNotBeCreated
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        try postHostInput(down)
        Thread.sleep(forTimeInterval: 0.015)
        try postHostInput(up)
    }

    private func postKey(_ type: CGEventType, code: CGKeyCode, shift: Bool) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp) else {
            throw G4Failure.eventCouldNotBeCreated
        }
        event.type = type
        event.flags = shift ? .maskShift : []
        try postHostInput(event)
    }

    private func postHostInput(_ event: CGEvent) throws {
        let postStartedAt = mach_absolute_time()
        event.post(tap: .cghidEventTap)
        let postCompletedAt = mach_absolute_time()
        hostInputEventCount += 1
        guard let screenCaptureEvidence else {
            throw G4Failure.screenRecordingStoppedDuringInput
        }
        do {
            try screenCaptureEvidence.recordHostInput(
                postStartedAt: postStartedAt,
                postCompletedAt: postCompletedAt
            )
            recordedHostInputEventCount += 1
        } catch {
            throw G4Failure.screenRecordingStoppedDuringInput
        }
    }

    private func launchOutput() -> String {
        String(decoding: (try? Data(contentsOf: launchOutputURL)) ?? Data(), as: UTF8.self)
    }

    private func runCLI(_ arguments: [String], timeout: TimeInterval) throws -> G4CommandResult {
        try runProcess(inputs.cli, arguments, timeout: timeout, environment: childEnvironment)
    }

    private func runProcess(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]? = nil
    ) throws -> G4CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let outputURL = inputs.artifacts.appendingPathComponent("command-\(adbLogNumber).log")
        adbLogNumber += 1
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw G4Failure.commandFailed(arguments.joined(separator: " "), 1, "could not create output file")
        }
        let outputFile = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = outputFile
        process.standardError = outputFile
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 5)
            try? outputFile.close()
            throw G4Failure.commandTimedOut(arguments.joined(separator: " "))
        }
        try outputFile.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        try writeArtifact("commands.log", "\(arguments.joined(separator: " "))\n\(output)\n")
        return G4CommandResult(status: process.terminationStatus, output: output)
    }

    private func writeArtifact(_ name: String, _ text: String) throws {
        let url = inputs.artifacts.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            _ = try handle.seekToEnd()
            handle.write(Data(text.utf8))
            try handle.close()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func windows(onScreenOnly: Bool) -> [G4Window] {
        let options: CGWindowListOption =
            onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.excludeDesktopElements]
        let records = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return records.compactMap { record in
            guard
                let number = (record[kCGWindowNumber as String] as? NSNumber)?.intValue,
                let owner = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let title = record[kCGWindowName as String] as? String,
                let bounds = record[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else {
                return nil
            }
            return G4Window(
                number: number,
                owner: owner,
                title: title,
                frame: CGRect(x: x, y: y, width: width, height: height)
            )
        }
    }

    private static func clickNumbers(in lines: [String]) -> [Int] {
        lines.compactMap { line in
            guard let range = line.range(of: G4NativeWindowTests.clickPrefix) else {
                return nil
            }
            return Int(line[range.upperBound...].prefix(while: \.isNumber))
        }
    }

    private static func screenNames(in lines: [String]) -> [String] {
        lines.compactMap { line in
            guard let range = line.range(of: G4NativeWindowTests.screenPrefix) else {
                return nil
            }
            return String(line[range.upperBound...].prefix(while: { $0.isLetter }))
        }
    }

    private static func adbCount(in line: String) -> Int? {
        guard let range = line.range(of: adbCountPrefix) else {
            return nil
        }
        return Int(line[range.upperBound...].prefix(while: \.isNumber))
    }

    private static func firstMatch(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> G4RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
            let wholeRange = Range(match.range, in: text)
        else {
            return nil
        }
        var captures: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let capture = Range(match.range(at: index), in: text) else {
                captures.append("")
                continue
            }
            captures.append(String(text[capture]))
        }
        return G4RegexMatch(whole: String(text[wholeRange]), captures: captures)
    }
}

private struct G4CommandResult {
    let status: Int32
    let output: String
}

private struct G4RegexMatch {
    let whole: String
    let captures: [String]

    subscript(_ index: Int) -> String {
        captures[index - 1]
    }
}

private struct G4DisplaySize {
    let width: Int
    let height: Int
}

private struct G4PixelRect {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double

    var center: CGPoint {
        CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
    }
}

private struct G4ViewInfo {
    let bounds: G4PixelRect
    let focused: Bool
}

private struct G4Window {
    let number: Int
    let owner: pid_t
    let title: String
    let frame: CGRect

    func point(for pixel: CGPoint, displaySize: G4DisplaySize) -> CGPoint {
        let contentHeight = frame.width * CGFloat(displaySize.height) / CGFloat(displaySize.width)
        let titleBarHeight = frame.height - contentHeight
        return CGPoint(
            x: frame.minX + pixel.x * frame.width / CGFloat(displaySize.width),
            y: frame.minY + titleBarHeight + pixel.y * contentHeight / CGFloat(displaySize.height)
        )
    }
}

private struct G4USKey {
    let code: CGKeyCode
    let shift: Bool

    static let tab = G4USKey(code: 0x30, shift: false)
    static let escape = G4USKey(code: 0x35, shift: false)

    static func typing(_ character: Character) -> G4USKey? {
        if let code = unshifted[character] {
            return G4USKey(code: code, shift: false)
        }
        if let code = shifted[character] {
            return G4USKey(code: code, shift: true)
        }
        if character.isUppercase, let code = unshifted[Character(character.lowercased())] {
            return G4USKey(code: code, shift: true)
        }
        return nil
    }

    private static let unshifted: [Character: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        ",": 0x2B, "n": 0x2D, "m": 0x2E, ".": 0x2F, " ": 0x31,
    ]
    private static let shifted: [Character: CGKeyCode] = ["!": 0x12]
}
