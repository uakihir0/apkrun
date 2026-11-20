import ArgumentParser
import Foundation

/// The performance harness (diagnostics.md §9.2). Drives the product like a
/// user — the `apkrun` CLI, `NSWorkspace`, synthesized events — and writes
/// `results.json` and `summary.md` per run directory.
@main
struct ApkrunPerf: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apkrun-perf",
        abstract: "Run APKRun performance scenarios (diagnostics.md §9.3)."
    )

    @Argument(
        help:
            "warm-launch | suspended-launch | cold-launch | input-latency | hellogl-fps | idle-cpu | update-check-launch | boot-phases | memory | all"
    )
    var scenario: String

    @Option(help: "Measured runs per scenario; the default comes from the scenario.")
    var runs: Int?

    @Option(help: "Warm-up runs discarded before measuring.")
    var warmup: Int?

    @Option(help: "Directory the results are written to; default <cwd>/perf-results.")
    var output: String?

    @Option(help: "Baseline file to compare against (baselines/<model>.json).")
    var baseline: String?

    @Option(help: "Path of the apkrun CLI binary; default looks on PATH.")
    var apkrun: String?

    @Option(help: "Path of APKRunLauncher.app used while wrappers do not exist (#76).")
    var launcher: String?

    mutating func run() async throws {
        let names: [String]
        if scenario == "all" {
            names = ScenarioRegistry.all
        } else {
            guard ScenarioRegistry.all.contains(scenario) else {
                throw ValidationError(
                    "unknown scenario '\(scenario)'; choices: \(ScenarioRegistry.all.joined(separator: ", "))")
            }
            names = [scenario]
        }

        let outputRoot = URL(fileURLWithPath: output ?? "perf-results", isDirectory: true)
        let context = PerfContext(
            apkrunPath: apkrun,
            launcherURL: launcher.map { URL(fileURLWithPath: $0) },
            runsOverride: runs,
            warmupOverride: warmup
        )

        let preconditions = PerfPreconditions.check()
        if let failure = preconditions.failure {
            FileHandle.standardError.write(
                Data("precondition failed: \(failure)\n".utf8))
            throw ExitCode(2)
        }

        var results: [ScenarioResult] = []
        for name in names {
            FileHandle.standardError.write(Data("apkrun-perf: running \(name)\n".utf8))
            let result = await ScenarioRegistry.run(
                name: name, context: context, preconditions: preconditions)
            results.append(result)
            if let reason = result.skipReason {
                FileHandle.standardError.write(Data("apkrun-perf: \(name) skipped: \(reason)\n".utf8))
            }
        }

        let baselineResults = try baseline.map { try PerfBaseline.load(from: URL(fileURLWithPath: $0)) }
        let directory = try PerfResultsWriter.write(
            results: results,
            preconditions: preconditions,
            baseline: baselineResults,
            to: outputRoot
        )
        FileHandle.standardOutput.write(Data("\(directory.path)\n".utf8))
    }
}
