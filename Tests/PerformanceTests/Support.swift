import Foundation
import RuntimeAPI
import RuntimeClient

/// Everything a scenario needs from the outside world.
struct PerfContext {
    /// Path of the `apkrun` binary; nil resolves it on PATH.
    var apkrunPath: String?
    /// The generic launcher used until `apkrun wrap` exists (#76).
    var launcherURL: URL?
    var runsOverride: Int?
    var warmupOverride: Int?

    func apkrun(_ arguments: [String]) throws -> String {
        try Shell.run(executable: resolvedApkrun(), arguments: arguments)
    }

    private func resolvedApkrun() throws -> String {
        if let apkrunPath { return apkrunPath }
        let found = try? Shell.run(
            executable: "/usr/bin/env", arguments: ["which", "apkrun"]
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let found, !found.isEmpty else {
            throw PerfFailure("apkrun is not on PATH; pass --apkrun")
        }
        return found
    }
}

/// One harness-visible failure, surfaced without a number.
struct PerfFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Runs a process and returns its stdout.
enum Shell {
    @discardableResult
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 120) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw PerfFailure("\(executable) timed out after \(Int(timeout)) s")
        }
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw PerfFailure(
                "\(executable) exited \(process.terminationStatus): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        return out
    }
}

/// The preconditions of diagnostics.md §9.2. A failed one stops the run.
struct PerfPreconditions {
    var onACPower: Bool
    var lowPowerModeOff: Bool
    var thermalNominal: Bool
    var otherVMsAbsent: Bool
    var fixturesInstalled: [String]
    var launchPath: String
    var failure: String?

    /// The fixture packages the launch scenarios need.
    static let fixturePackages = [
        "io.apkrun.fixture.hellotext",
        "io.apkrun.fixture.hellogl",
    ]

    static func check() -> PerfPreconditions {
        var result = PerfPreconditions(
            onACPower: true, lowPowerModeOff: true, thermalNominal: true,
            otherVMsAbsent: true, fixturesInstalled: [], launchPath: "launcher")
        result.lowPowerModeOff = !ProcessInfo.processInfo.isLowPowerModeEnabled
        result.thermalNominal = ProcessInfo.processInfo.thermalState == .nominal
        result.onACPower = isOnACPower()
        result.otherVMsAbsent = otherVMsAbsent()
        if !result.lowPowerModeOff { result.failure = "Low Power Mode is on" }
        if !result.thermalNominal {
            result.failure = "thermal state is \(ProcessInfo.processInfo.thermalState.rawValue)"
        }
        if !result.onACPower { result.failure = "not on AC power" }
        if !result.otherVMsAbsent { result.failure = "another virtual machine is running" }
        return result
    }

    private static func isOnACPower() -> Bool {
        guard let output = try? Shell.run(executable: "/usr/bin/pmset", arguments: ["-g", "ps"])
        else { return true }
        return output.contains("AC Power")
    }

    private static func otherVMsAbsent() -> Bool {
        guard
            let output = try? Shell.run(
                executable: "/usr/bin/pgrep", arguments: ["-fl", "UTM|Parallels|VirtualBox|vmware"],
                timeout: 15)
        else { return true }
        return output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One `perf/launches.jsonl` record (diagnostics.md §4.3).
struct LaunchRecord: Decodable {
    let v: Int
    let recordedAt: String
    let packageID: String
    let launchState: String
    let windowMode: String
    let markers: [String: Double]
    let totalMs: Double
    let outcome: String
}

/// Reads `perf/launches.jsonl` incrementally.
struct LaunchRecordLog {
    let url: URL

    static var `default`: LaunchRecordLog {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/APKRun/logs/perf")
        return LaunchRecordLog(url: root.appendingPathComponent("launches.jsonl"))
    }

    func records() -> [LaunchRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { line in
                line.data(using: .utf8).flatMap { try? decoder.decode(LaunchRecord.self, from: $0) }
            }
    }

    /// Waits for a record of `packageID` written after `since` with `firstFrameDisplayed`.
    func awaitRecord(packageID: String, sinceLineCount: Int, timeout: TimeInterval) async -> LaunchRecord? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let all = records()
            if all.count > sinceLineCount,
                let record = all[sinceLineCount...].first(where: {
                    $0.packageID == packageID && $0.markers["FIRST_FRAME_DISPLAYED"] != nil
                })
            {
                return record
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }
}

/// p50/p95 on doubles; p95 uses the nearest-rank rule of markerStatistics.
enum Percentiles {
    static func p50(_ values: [Double]) -> Double { percentile(values, 50) }
    static func p95(_ values: [Double]) -> Double { percentile(values, 95) }

    static func percentile(_ values: [Double], _ p: Int) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, (sorted.count * p + 99) / 100 - 1)
        return sorted[max(0, index)]
    }
}

/// Environment details recorded in every results.json (§9.4).
struct PerfEnvironment: Codable {
    var macModel: String
    var macOSVersion: String
    var apkrunBuild: String
    var imageVersion: String

    static func current(context: PerfContext) -> PerfEnvironment {
        let model =
            (try? Shell.run(
                executable: "/usr/sbin/sysctl", arguments: ["-n", "hw.model"], timeout: 15))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        var build = "unknown"
        if let output = try? context.apkrun(["--version"]) {
            build = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return PerfEnvironment(
            macModel: model,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            apkrunBuild: build,
            imageVersion: "unknown")
    }
}
