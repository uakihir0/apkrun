import Foundation

/// One statistics line of the development window, as `apkrun dev boot --stats` writes it to standard error.
///
/// The tearing counters are present only in a build with the TestReadback trait (CLI DisplayPump, graphics.md §12 #023).
struct G3StatisticsLine: Equatable {
    let framesPerSecond: Int
    let hostReadbacks: UInt64
    let cpuPixelCopies: UInt64
    /// Cumulative since the boot: frames read by the test-only tearing sampler.
    let framesSampled: Int?
    let redFrames: Int?
    let blueFrames: Int?
    let mixedFrames: Int?
    /// Cumulative since the boot: buffers the tearing sampler could not lock or read. Any is a failure.
    let unreadable: Int?

    init(
        framesPerSecond: Int, hostReadbacks: UInt64, cpuPixelCopies: UInt64,
        framesSampled: Int?, redFrames: Int?, blueFrames: Int?, mixedFrames: Int?, unreadable: Int? = nil
    ) {
        self.framesPerSecond = framesPerSecond
        self.hostReadbacks = hostReadbacks
        self.cpuPixelCopies = cpuPixelCopies
        self.framesSampled = framesSampled
        self.redFrames = redFrames
        self.blueFrames = blueFrames
        self.mixedFrames = mixedFrames
        self.unreadable = unreadable
    }

    /// Parses a line of the form `APKRun display 0  60 fps  dropped 0  stalls 0  hostReadbacks 0  cpuPixelCopies 0`.
    init?(line: String) {
        guard line.hasPrefix("APKRun display 0") else {
            return nil
        }
        let tokens = line.split(whereSeparator: { $0 == " " }).map(String.init)
        guard let fpsIndex = tokens.firstIndex(of: "fps"), fpsIndex > 0,
            let fps = Int(tokens[fpsIndex - 1])
        else {
            return nil
        }
        var values: [String: String] = [:]
        var index = fpsIndex + 1
        while index + 1 < tokens.count {
            values[tokens[index]] = tokens[index + 1]
            index += 2
        }
        guard let hostReadbacks = values["hostReadbacks"].flatMap(UInt64.init),
            let cpuPixelCopies = values["cpuPixelCopies"].flatMap(UInt64.init)
        else {
            return nil
        }
        framesPerSecond = fps
        self.hostReadbacks = hostReadbacks
        self.cpuPixelCopies = cpuPixelCopies
        framesSampled = values["framesSampled"].flatMap(Int.init)
        redFrames = values["redFrames"].flatMap(Int.init)
        blueFrames = values["blueFrames"].flatMap(Int.init)
        mixedFrames = values["mixedFrames"].flatMap(Int.init)
        unreadable = values["unreadable"].flatMap(Int.init)
    }
}

/// How the boot ended at the gate's stop (AcceptanceTests G3Session.stopBoot).
enum G3BootStop: String, Equatable {
    /// No boot was started.
    case notStarted
    /// The boot had ended before the stop was requested.
    case endedBeforeStop
    /// The boot ended within 60 s of SIGINT.
    case endedAfterInterrupt
    /// The boot was still running 60 s after SIGINT, and it was killed.
    case killedAfterInterrupt
}

/// The measurements of one G3 run, and the verdict on each of its conditions (roadmap.md §2, gate G3).
struct G3Measurements {
    /// The `renderer` event of HelloGL, for example `APKRUN-FIXTURE: renderer virgl`, or `nil` when there is none.
    var rendererEvent: String?
    /// The GLES lines of `dumpsys SurfaceFlinger`.
    var surfaceFlingerGLES: String = ""
    /// Whether the window of display 0 was found and its capture shows the display.
    var windowFound = false
    /// The number of distinct colours sampled from the first window capture.
    var distinctColoursInWindow = 0
    /// The statistics lines from the first HelloGL launch to the end of the run.
    var statisticsDuringRun: [G3StatisticsLine] = []
    /// The statistics lines of the first 60 s of the run.
    var statisticsFirstSixtySeconds: [G3StatisticsLine] = []
    /// The frame rates of HelloGL's `fps` events in the 10-minute run.
    var fpsEvents: [Double] = []
    /// The HelloGL pid at the start of the 10-minute run and at each minute mark.
    var pidAtStart: String?
    var pidAtMinute: [String?] = []
    /// The tearing counts of the alternating-colour phase: the change of the cumulative counters over that phase.
    var alternatingRedFrames = 0
    var alternatingBlueFrames = 0
    var alternatingMixedFrames = 0
    var alternatingSampledFrames = 0
    /// Crash lines that name HelloGL or SurfaceFlinger, in the 10-minute run.
    var rendererCrashLines: [String] = []
    /// Crash lines of other processes in the 10-minute run. They are recorded and do not fail G3 (IR-1208).
    var otherCrashLines = 0
    /// How the boot ended at the stop. Only `endedAfterInterrupt` passes condition 5 of the stop rule.
    var bootStop: G3BootStop = .notStarted
    /// The buffers the tearing sampler could not read, cumulative over the boot.
    var unreadableFrames = 0
}

/// The pure checks of G3. The gate test measures, and this type says which of the conditions fail.
enum G3Evidence {
    /// The minimum frame rate of the 10-minute run (NFR-PERF-04, roadmap.md §2 condition 4).
    static let minimumAverageFramesPerSecond = 55.0
    /// The number of HelloGL `fps` events of a full 10-minute run (one every 10 s), with a margin for timing.
    static let minimumFpsEvents = 50
    /// The statistics lines of a 60 s window, with a margin for timing.
    static let minimumStatisticsLinesInSixtySeconds = 50
    /// The alternating-colour frames of each colour that the phase must show, so the alternation was observed.
    static let minimumAlternatingFramesPerColour = 30
    /// Distinct colours that a window capture must show to count as the display rather than a blank window.
    static let minimumDistinctColours = 8

    /// The conditions that fail, each named as the roadmap names it. An empty list is a pass.
    static func failures(_ measurements: G3Measurements) -> [String] {
        var failures: [String] = []
        if !measurements.windowFound || measurements.distinctColoursInWindow < minimumDistinctColours {
            failures.append(
                "1 the Android display is visible in the window (found \(measurements.windowFound), "
                    + "\(measurements.distinctColoursInWindow) distinct colours)")
        }
        let gles = measurements.surfaceFlingerGLES.lowercased()
        if !gles.contains("virgl") {
            failures.append("2 SurfaceFlinger does not report the virgl GLES renderer")
        }
        if !(measurements.rendererEvent ?? "").contains("virgl") {
            failures.append("2 HelloGL's renderer event is not virgl (\(measurements.rendererEvent ?? "none"))")
        }
        let readbacks = measurements.statisticsDuringRun.filter {
            $0.hostReadbacks != 0 || $0.cpuPixelCopies != 0
        }
        if measurements.statisticsDuringRun.isEmpty {
            failures.append("3 no statistics line was logged during the run")
        }
        if !readbacks.isEmpty {
            failures.append("3 \(readbacks.count) statistics lines report a readback or a CPU pixel copy")
        }
        if measurements.statisticsFirstSixtySeconds.count < minimumStatisticsLinesInSixtySeconds {
            failures.append(
                "3 the 60 s window has \(measurements.statisticsFirstSixtySeconds.count) statistics lines")
        }
        let average =
            measurements.fpsEvents.isEmpty
            ? 0 : measurements.fpsEvents.reduce(0, +) / Double(measurements.fpsEvents.count)
        if measurements.fpsEvents.count < minimumFpsEvents || average < minimumAverageFramesPerSecond {
            failures.append(
                "4 HelloGL averages \(String(format: "%.2f", average)) fps over \(measurements.fpsEvents.count) "
                    + "events (need at least \(minimumAverageFramesPerSecond) over \(minimumFpsEvents))")
        }
        if measurements.alternatingMixedFrames != 0 {
            failures.append("4 \(measurements.alternatingMixedFrames) sampled frames hold both colours (tearing)")
        }
        if measurements.alternatingRedFrames < minimumAlternatingFramesPerColour
            || measurements.alternatingBlueFrames < minimumAlternatingFramesPerColour
        {
            failures.append(
                "4 the alternating phase showed \(measurements.alternatingRedFrames) red and "
                    + "\(measurements.alternatingBlueFrames) blue frames; the alternation was not observed")
        }
        let pids = [measurements.pidAtStart] + measurements.pidAtMinute
        let allArePIDs = pids.allSatisfy { pid in pid.map(isProcessID) ?? false }
        if pids.count != 11 || !allArePIDs || Set(pids.compactMap { $0 }).count != 1 {
            failures.append("5 the HelloGL pid changed or was missing during the 10-minute run: \(pids)")
        }
        if measurements.unreadableFrames != 0 {
            failures.append("4 the tearing sampler could not read \(measurements.unreadableFrames) buffers")
        }
        if !measurements.rendererCrashLines.isEmpty {
            failures.append("5 \(measurements.rendererCrashLines.count) renderer crash lines in the 10-minute run")
        }
        if measurements.bootStop != .endedAfterInterrupt {
            failures.append("5 the boot did not end within 60 s of SIGINT (\(measurements.bootStop.rawValue))")
        }
        return failures
    }

    /// Whether `text` is one process id: ASCII digits only. An adb error text is not a pid.
    static func isProcessID(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    /// Whether a logcat line is a crash of the renderer: HelloGL or SurfaceFlinger with a fatal marker.
    static func isRendererCrash(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let names = lowered.contains("hellogl") || lowered.contains("surfaceflinger")
        let markers = ["fatal", "has died", "sigabrt", "sigsegv", "f libc", "f debug", "androidruntime", "tombstone"]
        return names && markers.contains { lowered.contains($0) }
    }

    /// Whether a logcat line is any crash, so that the crashes of other processes can be counted.
    static func isAnyCrash(_ line: String) -> Bool {
        let lowered = line.lowercased()
        let markers = ["fatal", "has died", "sigabrt", "sigsegv", "f libc", "f debug", "androidruntime", "tombstone"]
        return markers.contains { lowered.contains($0) }
    }

    /// The frame rates of HelloGL's `APKRUN-FIXTURE: fps <average>` lines.
    static func fpsEvents(in logcat: String) -> [Double] {
        logcat.split(whereSeparator: \.isNewline).compactMap { line in
            guard let range = line.range(of: "APKRUN-FIXTURE: fps ") else {
                return nil
            }
            return Double(line[range.upperBound...].split(separator: " ").first ?? "")
        }
    }

    /// The `renderer` event of HelloGL, or `nil`.
    static func rendererEvent(in logcat: String) -> String? {
        logcat.split(whereSeparator: \.isNewline).map(String.init).first {
            $0.contains("APKRUN-FIXTURE: renderer ")
        }.map { line in
            let range = line.range(of: "APKRUN-FIXTURE: renderer ")!
            return "APKRUN-FIXTURE: renderer " + line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        }
    }
}
