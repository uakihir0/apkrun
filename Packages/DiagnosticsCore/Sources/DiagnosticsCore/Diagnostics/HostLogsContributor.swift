import Foundation

/// `host/logs/`: the unified-log extract (45 s budget), the file mirrors
/// `apkrund.log*`, and the `.ips` crash reports of APKRun processes from the
/// last 7 days, at most 20 (diagnostics.md §8.2).
public struct HostLogsContributor: DiagnosticsContributor {
    /// The owning module's name.
    public let name = "host"
    /// `log show` gets the 45 s budget of §8.1.
    public let budget = Duration.seconds(45)

    /// The `log show --last` window.
    public var window = "24h"
    /// The byte cap of `logs/unified.ndjson` (newest 30 MiB).
    public var unifiedCap = 30 * 1024 * 1024
    /// The crash-report processes of §8.2.
    public var crashProcesses = [
        "apkrund", "APKRun", "APKRunMenuBar", "apkrun", "APKRunLauncher",
    ]
    /// `~` replaced by the caller to keep `~` reduction stable.
    public var mirrorDirectory: URL?
    /// The directory `log show`'s mirrors are read from when `log show`
    /// fails; the files are copied as `logs/mirrors/apkrund.log*`.
    public var crashReportDirectories: [URL]
    /// How the contributor runs `log show`; injectable for tests. Receives
    /// the predicate arguments and returns the output text.
    public var logShow: @Sendable (String) throws -> String = { predicate in
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "24h", "--style", "ndjson",
            "--predicate", predicate,
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Creates the contributor.
    /// - Parameters:
    ///   - mirrorDirectory: the log-mirror directory (`logs/` under the state
    ///     directory); nil skips `logs/mirrors/`.
    ///   - crashReportDirectories: searched for `<process>-*.ips` files; the
    ///     default is `~/Library/Logs/DiagnosticReports`.
    public init(
        mirrorDirectory: URL? = nil,
        crashReportDirectories: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports")
        ]
    ) {
        self.mirrorDirectory = mirrorDirectory
        self.crashReportDirectories = crashReportDirectories
    }

    /// Writes `host/logs/unified.ndjson` (or the mirrors on failure),
    /// `host/logs/mirrors/`, and `host/crash-reports/`.
    public func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws {
        // Unified log: APKRun subsystems only (§6.1 keeps other subsystems
        // out of the predicate entirely).
        do {
            let text = try logShow("subsystem BEGINSWITH \"io.apkrun\"")
            let cut = DiagnosticsAllowlists.cutAtUnitSeparator(text)
            try bundle.add(
                "host/logs/unified.ndjson",
                text: Self.newestBytes(cut, cap: unifiedCap))
        } catch {
            bundle.omit("host/logs/unified.ndjson", reason: "logShowFailed")
        }

        // Mirrors: apkrund.log* keep the last 1 MiB each.
        if let mirrorDirectory {
            if let files = try? FileManager.default.contentsOfDirectory(
                atPath: mirrorDirectory.path)
            {
                for file in files.sorted() where file.hasPrefix("apkrund.log") {
                    let url = mirrorDirectory.appendingPathComponent(file)
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let trimmed = data.count > 1_048_576 ? data.suffix(1_048_576) : data
                    try bundle.add(
                        "host/logs/mirrors/\(file)",
                        text: DiagnosticsAllowlists.cutAtUnitSeparator(
                            String(decoding: trimmed, as: UTF8.self)))
                }
            }
        }

        // Crash reports: newest 20 .ips of APKRun processes, last 7 days.
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var reports: [(url: URL, date: Date)] = []
        for directory in crashReportDirectories {
            guard
                let files = try? FileManager.default.contentsOfDirectory(
                    atPath: directory.path)
            else { continue }
            for file in files where file.hasSuffix(".ips") {
                guard
                    crashProcesses.contains(where: { file.hasPrefix("\($0)-") })
                        || crashProcesses.contains(
                            file.replacingOccurrences(
                                of: ".ips", with: ""))
                else { continue }
                let url = directory.appendingPathComponent(file)
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let date = (attributes?[.modificationDate] as? Date) ?? .distantPast
                guard date > cutoff else { continue }
                reports.append((url: url, date: date))
            }
        }
        for report in reports.sorted(by: { $0.date > $1.date }).prefix(20) {
            guard let data = try? Data(contentsOf: report.url) else { continue }
            try bundle.add(
                "host/crash-reports/\(report.url.lastPathComponent)",
                data: data)
        }
    }

    /// The newest `cap` bytes of `text`, cut on a line boundary.
    static func newestBytes(_ text: String, cap: Int) -> String {
        let utf8 = Array(text.utf8)
        guard utf8.count > cap else { return text }
        var start = utf8.count - cap
        while start < utf8.count, utf8[start] != UInt8(ascii: "\n") {
            start += 1
        }
        start = min(start + 1, utf8.count)
        let lines = utf8[start...]
        var result = "[earlier log omitted]\n"
        result += String(decoding: lines, as: UTF8.self)
        return result
    }
}

/// `host/perf/`: the newest records of `launches.jsonl` (500) and
/// `boots.jsonl` (50) (§8.2).
public struct PerfContributor: DiagnosticsContributor {
    /// The owning module's name.
    public let name = "host"
    /// Two small files.
    public let budget = Duration.seconds(10)

    /// `perf/launches.jsonl` under the state directory.
    public var launchesFile: URL
    /// `perf/boots.jsonl` under the state directory.
    public var bootsFile: URL

    /// Creates the contributor.
    public init(launchesFile: URL, bootsFile: URL) {
        self.launchesFile = launchesFile
        self.bootsFile = bootsFile
    }

    /// Writes the tail of both records files.
    public func contribute(to bundle: DiagnosticsBundleBuilder, options: DiagnosticsOptions) async throws {
        for (source, destination, limit) in [
            (launchesFile, "host/perf/launches.jsonl", 500),
            (bootsFile, "host/perf/boots.jsonl", 50),
        ] as [(URL, String, Int)] {
            guard let text = try? String(contentsOf: source, encoding: .utf8) else {
                bundle.omit(destination, reason: "unavailable")
                continue
            }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let tail = lines.suffix(limit).joined(separator: "\n")
            try bundle.add(destination, text: tail + "\n")
        }
    }
}
