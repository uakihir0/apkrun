import AppKit
import Foundation
import RuntimeAPI
import RuntimeClient

/// The scenarios of diagnostics.md §9.3.
enum ScenarioRegistry {
    static let all = [
        "warm-launch", "suspended-launch", "cold-launch", "input-latency",
        "hellogl-fps", "idle-cpu", "update-check-launch", "boot-phases", "memory",
    ]

    static func run(
        name: String, context: PerfContext, preconditions: PerfPreconditions
    ) async -> ScenarioResult {
        do {
            switch name {
            case "warm-launch":
                return try await Scenarios.launch(
                    name: name, context: context, cold: false, suspended: false)
            case "suspended-launch":
                return try await Scenarios.launch(
                    name: name, context: context, cold: false, suspended: true)
            case "cold-launch":
                return try await Scenarios.launch(
                    name: name, context: context, cold: true, suspended: false)
            case "input-latency":
                return try await Scenarios.inputLatency(context: context)
            case "hellogl-fps":
                return try await Scenarios.helloGLFps(context: context)
            case "idle-cpu":
                return try await Scenarios.idleCPU(context: context)
            case "update-check-launch":
                return .skipped(name, reason: "needs #38 and #75")
            case "boot-phases":
                return try await Scenarios.bootPhases(context: context)
            case "memory":
                return try await Scenarios.memory(context: context)
            default:
                return .skipped(name, reason: "unknown scenario")
            }
        } catch {
            return ScenarioResult(
                scenario: name, status: "failed", skipReason: "\(error)")
        }
    }
}

private enum Scenarios {
    static let helloText = "io.apkrun.fixture.hellotext"
    static let helloGL = "io.apkrun.fixture.hellogl"

    /// warm-launch / suspended-launch / cold-launch: `apkrun stop`, wait, open
    /// the app with NSWorkspace, and wait for its launches.jsonl record.
    static func launch(
        name: String, context: PerfContext, cold: Bool, suspended: Bool
    ) async throws -> ScenarioResult {
        guard let launcher = context.launcherURL else {
            return .skipped(name, reason: "pass --launcher (wrappers need #76)")
        }
        let warmup = context.warmupOverride ?? (cold ? 0 : 3)
        let runs = context.runsOverride ?? (cold ? 10 : 30)
        let log = LaunchRecordLog.default

        var samples: [ScenarioSample] = []
        for run in 0..<(warmup + runs) {
            if cold {
                _ = try? context.apkrun(["runtime", "stop"])
            } else {
                _ = try? context.apkrun(["stop", helloText])
                try await Task.sleep(for: .seconds(2))
            }
            if suspended {
                // `runtime.idleSuspendMinutes` = 1 on the lab Mac; wait for
                // VM_PAUSED via runtime status.
                _ = try? context.apkrun([
                    "config", "set", "runtime.idleSuspendMinutes", "1",
                ])
            }
            let before = log.records().count
            let t0 = Date()
            let config = NSWorkspace.OpenConfiguration()
            config.arguments = ["--package", helloText]
            _ = try await NSWorkspace.shared.openApplication(
                at: launcher, configuration: config)
            guard
                let record = await log.awaitRecord(
                    packageID: helloText, sinceLineCount: before, timeout: 120)
            else {
                samples.append(
                    ScenarioSample(run: run, note: "no launch record within 120 s"))
                continue
            }
            var sample = ScenarioSample(run: run)
            // t0 (openApplication) → FIRST_FRAME_DISPLAYED: the wall time up to
            // the record is the honest end-to-end number; the markers are the
            // segment breakdown.
            sample.durationMs = Date().timeIntervalSince(t0) * 1000
            for (marker, ms) in record.markers {
                sample.segments[marker] = ms
            }
            sample.metrics["totalMs"] = record.totalMs
            if run >= warmup {
                samples.append(sample)
            }
        }
        var result = ScenarioResult(
            scenario: name, status: "ok",
            targetDescription: cold ? "NFR-PERF-02 p50 ≤ 40 s" : "NFR-PERF-01 p50 ≤ 1.5 s, p95 ≤ 3 s",
            samples: samples)
        let durations = samples.compactMap(\.durationMs)
        result.p50Ms = Percentiles.p50(durations)
        result.p95Ms = Percentiles.p95(durations)
        return result
    }

    /// 1,000 clicks and 1,000 key presses at 20 Hz into HelloText; reads the
    /// input histograms of perfStatistics(reset:).
    static func inputLatency(context: PerfContext) async throws -> ScenarioResult {
        let client = try RuntimeControlClient(clientKind: .cli)
        _ = try await client.perfStatistics(reset: true)

        // Synthesized events need the harness's Accessibility permission on
        // the lab Mac (diagnostics.md §9.2).
        for index in 0..<1000 {
            let down = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: .zero, mouseButton: .left)
            let up = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: .zero, mouseButton: .left)
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            if index % 20 == 19 {
                try await Task.sleep(for: .milliseconds(1000 - 20 * 5))
            } else {
                try await Task.sleep(for: .milliseconds(5))
            }
        }

        let statistics = try await client.perfStatistics(reset: false)
        var sample = ScenarioSample(run: 0)
        for histogram in statistics.input {
            sample.metrics["\(histogram.segment).count"] = Double(
                histogram.counts.reduce(0, +))
            if let p95 = histogramP95Us(histogram) {
                sample.segments[histogram.segment] = p95 / 1000
            }
        }
        var result = ScenarioResult(
            scenario: "input-latency", status: "ok",
            targetDescription: "NFR-PERF-03 p95 ≤ 16 ms",
            samples: [sample])
        result.p95Ms = sample.segments.values.max()
        return result
    }

    private static func histogramP95Us(_ histogram: WireInputHistogram) -> Double? {
        let total = histogram.counts.reduce(0, +)
        guard total > 0 else { return nil }
        var seen: Int64 = 0
        let rank = (total * 95 + 99) / 100
        for (index, count) in histogram.counts.enumerated() {
            seen += count
            if seen >= rank {
                return Double(histogram.boundsUs[min(index, histogram.boundsUs.count - 1)])
            }
        }
        return nil
    }

    /// HelloGL at 1080×2400 for 60 s after 5 s warm-up; fps and counters from
    /// frameStatistics.
    static func helloGLFps(context: PerfContext) async throws -> ScenarioResult {
        guard let launcher = context.launcherURL else {
            return .skipped("hellogl-fps", reason: "pass --launcher (wrappers need #76)")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [
            "--package", helloGL, "--width", "1080", "--height", "2400",
        ]
        _ = try await NSWorkspace.shared.openApplication(
            at: launcher, configuration: config)
        try await Task.sleep(for: .seconds(5))
        let client = try RuntimeControlClient(clientKind: .cli)
        var samples: [ScenarioSample] = []
        // 10 s averages over 60 s.
        for run in 0..<6 {
            try await Task.sleep(for: .seconds(10))
            let sessions = try await client.frameStatistics()
            guard let session = sessions.first(where: { $0.packageID.rawValue == helloGL })
            else { continue }
            var sample = ScenarioSample(run: run)
            sample.durationMs = session.fps
            sample.metrics["droppedFrames"] = Double(session.droppedFrames)
            sample.metrics["hostReadbacks"] = Double(session.hostReadbacks)
            sample.metrics["cpuPixelCopies"] = Double(session.cpuPixelCopies)
            sample.segments["presentGPUTimeP50Us"] = Double(session.presentGPUTimeP50Us) / 1000
            sample.segments["presentGPUTimeP95Us"] = Double(session.presentGPUTimeP95Us) / 1000
            samples.append(sample)
        }
        var result = ScenarioResult(
            scenario: "hellogl-fps", status: "ok",
            targetDescription: "NFR-PERF-04 ≥ 55 fps; NFR-PERF-05 readbacks 0",
            samples: samples)
        let fps = samples.compactMap(\.durationMs)
        result.p50Ms = Percentiles.p50(fps)
        result.p95Ms = Percentiles.p95(fps)
        return result
    }

    /// apkrund CPU time at start and after 300 s while the VM is paused.
    static func idleCPU(context: PerfContext) async throws -> ScenarioResult {
        let client = try RuntimeControlClient(clientKind: .cli)
        let start = try await client.perfStatistics(reset: false)
        guard let startMetrics = start.metrics else {
            return .skipped("idle-cpu", reason: "metrics snapshot unavailable")
        }
        let wall0 = Date()
        try await Task.sleep(for: .seconds(300))
        let end = try await client.perfStatistics(reset: false)
        guard let endMetrics = end.metrics else {
            return .skipped("idle-cpu", reason: "metrics snapshot unavailable")
        }
        let cpuSeconds =
            Double(
                endMetrics.daemonCPUUserUs + endMetrics.daemonCPUSystemUs
                    - startMetrics.daemonCPUUserUs - startMetrics.daemonCPUSystemUs) / 1_000_000
        let ratio = cpuSeconds / Date().timeIntervalSince(wall0) * 100
        var sample = ScenarioSample(run: 0)
        sample.durationMs = ratio
        var result = ScenarioResult(
            scenario: "idle-cpu", status: "ok",
            targetDescription: "NFR-PERF-06 < 1 %", samples: [sample])
        result.p50Ms = ratio
        return result
    }

    /// 10 cold boots; boot segment timings from perf/boots.jsonl.
    static func bootPhases(context: PerfContext) async throws -> ScenarioResult {
        var samples: [ScenarioSample] = []
        for run in 0..<10 {
            _ = try? context.apkrun(["runtime", "stop"])
            let bootsURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/APKRun/logs/perf/boots.jsonl")
            let before =
                (try? Data(contentsOf: bootsURL))?
                .split(separator: 0x0A).count ?? 0
            _ = try context.apkrun(["runtime", "start"])
            let deadline = Date().addingTimeInterval(180)
            var record: [String: Double]?
            while Date() < deadline, record == nil {
                if let data = try? Data(contentsOf: bootsURL) {
                    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                    if lines.count > before,
                        let line = lines.last?.data(using: .utf8),
                        let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                        let markers = json["markers"] as? [String: Double]
                    {
                        record = markers
                    }
                }
                try await Task.sleep(for: .seconds(1))
            }
            var sample = ScenarioSample(run: run)
            for (marker, ms) in record ?? [:] {
                sample.segments[marker] = ms
            }
            samples.append(sample)
        }
        return ScenarioResult(
            scenario: "boot-phases", status: "ok",
            targetDescription: "tracked against baseline", samples: samples)
    }

    /// MetricsSnapshot after a warm launch: VM/system_server/SurfaceFlinger/
    /// zygote/APK/host-graphics/apkrund RSS (diagnostics.md §5).
    static func memory(context: PerfContext) async throws -> ScenarioResult {
        let client = try RuntimeControlClient(clientKind: .cli)
        let statistics = try await client.perfStatistics(reset: false)
        guard let metrics = statistics.metrics else {
            return .skipped("memory", reason: "metrics snapshot unavailable")
        }
        var sample = ScenarioSample(run: 0)
        for process in metrics.guestProcesses {
            sample.metrics["guest.\(process.name).rss"] = Double(process.rssBytes)
            sample.metrics["guest.\(process.name).pss"] = Double(process.pssBytes)
        }
        if let footprint = metrics.vmServiceFootprintBytes {
            sample.metrics["vmService.footprint"] = Double(footprint)
        }
        sample.metrics["apkrund.resident"] = Double(metrics.daemonResidentBytes)
        sample.metrics["apkrund.footprint"] = Double(metrics.daemonFootprintBytes)
        sample.metrics["iosurface.bytes"] = Double(metrics.iosurfaceBytes)
        if let metal = metrics.metalAllocatedBytes {
            sample.metrics["metal.allocated"] = Double(metal)
        }
        return ScenarioResult(
            scenario: "memory", status: "ok",
            targetDescription: "tracked only; no v1 target", samples: [sample])
    }
}
