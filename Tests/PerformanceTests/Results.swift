import Foundation

/// One measured run of a scenario.
struct ScenarioSample: Codable {
    var run: Int
    /// The scenario's primary measure in milliseconds.
    var durationMs: Double?
    /// Named segment durations in milliseconds.
    var segments: [String: Double] = [:]
    /// Extra scenario figures (fps, counters, histograms).
    var metrics: [String: Double] = [:]
    var note: String?
}

/// One scenario's outcome.
struct ScenarioResult: Codable {
    var scenario: String
    var status: String  // ok | skipped | failed
    var skipReason: String?
    var targetDescription: String?
    var samples: [ScenarioSample] = []
    var p50Ms: Double?
    var p95Ms: Double?

    static func skipped(_ scenario: String, reason: String) -> ScenarioResult {
        ScenarioResult(scenario: scenario, status: "skipped", skipReason: reason)
    }
}

/// Per-scenario baseline (§9.4), `Tests/PerformanceTests/baselines/<model>.json`.
struct PerfBaseline: Codable {
    struct Entry: Codable {
        var p50Ms: Double
        var p95Ms: Double?
    }
    var macModel: String
    var scenarios: [String: Entry]

    static func load(from url: URL) throws -> PerfBaseline {
        try JSONDecoder().decode(PerfBaseline.self, from: Data(contentsOf: url))
    }
}

/// The results.json root (§9.4).
struct PerfResultsFile: Codable {
    var schemaVersion: Int = 1
    var generatedAt: String
    var environment: PerfEnvironment
    var preconditions: [String: String]
    var launchPath: String
    var results: [ScenarioResult]
}

/// Writes `<output>/<timestamp>-<build>/results.json` and `summary.md` (§9.4).
enum PerfResultsWriter {
    @discardableResult
    static func write(
        results: [ScenarioResult],
        preconditions: PerfPreconditions,
        baseline: PerfBaseline?,
        to outputRoot: URL
    ) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let directory = outputRoot.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let file = PerfResultsFile(
            generatedAt: stamp,
            environment: PerfEnvironment(
                macModel: "unknown", macOSVersion: "", apkrunBuild: "", imageVersion: ""),
            preconditions: [
                "onACPower": "\(preconditions.onACPower)",
                "lowPowerModeOff": "\(preconditions.lowPowerModeOff)",
                "thermalNominal": "\(preconditions.thermalNominal)",
                "otherVMsAbsent": "\(preconditions.otherVMsAbsent)",
                "fixturesInstalled": preconditions.fixturesInstalled.joined(separator: ","),
            ],
            launchPath: preconditions.launchPath,
            results: results
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(
            to: directory.appendingPathComponent("results.json"))

        var markdown = "# apkrun-perf results\n\n"
        markdown += "| scenario | status | p50 | p95 | target | baseline p50 |\n"
        markdown += "|---|---|---|---|---|---|\n"
        for result in results {
            let p50 = result.p50Ms.map { String(format: "%.0f ms", $0) } ?? "—"
            let p95 = result.p95Ms.map { String(format: "%.0f ms", $0) } ?? "—"
            let base =
                baseline?.scenarios[result.scenario].map {
                    String(format: "%.0f ms", $0.p50Ms)
                } ?? "—"
            let status =
                result.status + (result.skipReason.map { " (\($0))" } ?? "")
            markdown +=
                "| \(result.scenario) | \(status) | \(p50) | \(p95) | \(result.targetDescription ?? "—") | \(base) |\n"
        }
        try markdown.write(
            to: directory.appendingPathComponent("summary.md"),
            atomically: true, encoding: .utf8)
        return directory
    }
}
