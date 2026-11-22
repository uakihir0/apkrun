import CryptoKit
import Foundation

/// A file record of `manifest.json` (diagnostics.md §8.2).
public struct DiagnosticsManifestFile: Sendable, Codable, Equatable {
    /// The path inside the bundle.
    public var path: String
    /// The uncompressed byte count.
    public var bytes: Int
    /// The SHA-256 of the uncompressed contents.
    public var sha256: String
    /// The contributor that produced it, when known.
    public var contributor: String?

    /// Creates a file record.
    public init(path: String, bytes: Int, sha256: String, contributor: String? = nil) {
        self.path = path
        self.bytes = bytes
        self.sha256 = sha256
        self.contributor = contributor
    }
}

/// `manifest.json`, format 1 (diagnostics.md §8.2).
public struct DiagnosticsManifest: Sendable, Codable, Equatable {
    /// The format version, always 1.
    public var format: Int = 1
    /// The random report ID.
    public var reportID: String
    /// ISO-8601 creation time.
    public var createdAt: String
    /// `apkrund`, `cli`, or `app`.
    public var createdBy: String
    /// `full` or `hostOnly`.
    public var mode: String
    /// The options the run was created with.
    public var options: Options
    /// The producing build, e.g. `1.0 (1000)`.
    public var build: String
    /// `RedactionRules.version` of the redactor that ran.
    public var redactionRulesVersion: Int
    /// Every file in the archive.
    public var files: [DiagnosticsManifestFile]
    /// Every missing item and its reason.
    public var omitted: [DiagnosticsOmittedItem]
    /// Per-rule redaction counts.
    public var redaction: [String: Int]
    /// Service counters worth reporting (e.g. `diagnostics.mirrorDropped`).
    public var counters: [String: Int]

    /// The manifest's nested options block.
    public struct Options: Sendable, Codable, Equatable {
        /// `--include-logcat` was on.
        public var includeLogcat: Bool
        /// `--deep` was on.
        public var deep: Bool
        /// The focus package, when given.
        public var focusPackage: String?

        /// Creates the options record.
        public init(includeLogcat: Bool, deep: Bool, focusPackage: String?) {
            self.includeLogcat = includeLogcat
            self.deep = deep
            self.focusPackage = focusPackage
        }
    }

    /// Creates a manifest.
    public init(
        reportID: String,
        createdAt: String,
        createdBy: String,
        mode: String,
        options: Options,
        build: String,
        redactionRulesVersion: Int,
        files: [DiagnosticsManifestFile],
        omitted: [DiagnosticsOmittedItem],
        redaction: [String: Int],
        counters: [String: Int]
    ) {
        self.reportID = reportID
        self.createdAt = createdAt
        self.createdBy = createdBy
        self.mode = mode
        self.options = options
        self.build = build
        self.redactionRulesVersion = redactionRulesVersion
        self.files = files
        self.omitted = omitted
        self.redaction = redaction
        self.counters = counters
    }
}

/// The facts `summary.txt` needs beyond the files themselves (§8.3).
public struct DiagnosticsSummaryContext: Sendable {
    /// The doctor status line, e.g. `Android failed to start`.
    public var statusLine: String
    /// The remediation sentence under the status line, when any.
    public var remediation: String?
    /// The build line: APKRun, apkrund, CLI, launcher, image, agent versions.
    public var buildLine: String
    /// Non-pass health rows: `✕ id title`, rendered by the doctor formatter.
    public var healthRows: [String]
    /// Recent `error`-level log entries: `<time> <code> op <id>`.
    public var recentProblems: [String]
    /// The apps line (installed count and names).
    public var appsLine: String?
    /// Why guest data is missing, when it is (`Android was not running`).
    public var guestMissingReason: String?
    /// The operation ID of the report run.
    public var operationID: String

    /// Creates a summary context.
    public init(
        statusLine: String,
        remediation: String? = nil,
        buildLine: String,
        healthRows: [String] = [],
        recentProblems: [String] = [],
        appsLine: String? = nil,
        guestMissingReason: String? = nil,
        operationID: String
    ) {
        self.statusLine = statusLine
        self.remediation = remediation
        self.buildLine = buildLine
        self.healthRows = healthRows
        self.recentProblems = recentProblems
        self.appsLine = appsLine
        self.guestMissingReason = guestMissingReason
        self.operationID = operationID
    }
}

/// The outcome of one `DiagnosticsBundleWriter.write` (§8.1).
public struct DiagnosticsBundleResult: Sendable {
    /// The text of `summary.txt`, for **Copy Summary** and the CLI.
    public var summary: String
    /// The compressed size of the archive.
    public var bytes: Int64
    /// Every omitted item.
    public var omitted: [DiagnosticsOmittedItem]

    /// Creates a result.
    public init(summary: String, bytes: Int64, omitted: [DiagnosticsOmittedItem]) {
        self.summary = summary
        self.bytes = bytes
        self.omitted = omitted
    }
}

/// Runs the redactor over the staged files, writes `summary.txt` and
/// `manifest.json`, and streams the ZIP into the client's handle
/// (diagnostics.md §8.1): staging directory 0700 in `$TMPDIR`, ZIP mode
/// 0600, staging deleted at the end and on cancel.
public final class DiagnosticsBundleWriter {
    /// The writer could not finish the archive.
    public enum Failure: Error {
        /// The staging directory could not be created.
        case stagingFailed(Error)
        /// The output handle could not be written.
        case writeFailed(Error)
        /// The archive attributes could not be set.
        case attributeFailed(Error)
    }

    private let redactor: Redactor
    private let options: DiagnosticsOptions
    private let build: String
    private let fileManager = FileManager.default

    /// Creates a writer for one report.
    /// - Parameters:
    ///   - redactor: the run's redactor (its counts go into the manifest).
    ///   - options: the run's options, mirrored into `manifest.json`.
    ///   - build: the producing build string for the manifest.
    public init(redactor: Redactor, options: DiagnosticsOptions, build: String) {
        self.redactor = redactor
        self.options = options
        self.build = build
    }

    /// The `summary.txt` body of diagnostics.md §8.3.
    public static func summary(options: DiagnosticsOptions, context: DiagnosticsSummaryContext) -> String {
        var lines: [String] = ["APKRun Diagnostics Report"]
        let stamp = ISO8601DateFormatter().string(from: options.createdAt)
        lines.append(
            "Created \(stamp) · Report \(String(options.reportID.prefix(8)))"
                + " · operation \(String(context.operationID.prefix(8)))")
        lines.append("")
        lines.append("Status: \(context.statusLine)")
        if let remediation = context.remediation {
            lines.append("  Suggested: \(remediation)")
        }
        lines.append("")
        lines.append("Build: \(context.buildLine)")
        if !context.healthRows.isEmpty {
            let failures = context.healthRows.filter { $0.hasPrefix("✕") }.count
            let warnings = context.healthRows.count - failures
            lines.append("")
            lines.append(
                "Health: \(failures) failure(s), \(warnings) warning(s) (see host/health.txt)")
            for row in context.healthRows {
                lines.append("  \(row)")
            }
        }
        if !context.recentProblems.isEmpty {
            lines.append("")
            lines.append("Recent problems (last 7 days, from logs)")
            for problem in context.recentProblems {
                lines.append("  \(problem)")
            }
        }
        if let appsLine = context.appsLine {
            lines.append("")
            lines.append(appsLine)
        }
        lines.append("")
        lines.append("Privacy")
        lines.append(
            "  Not collected: clipboard, notification text, your files, app data,"
                + " accounts, passwords, Keychain items.")
        if let reason = context.guestMissingReason {
            lines.append("  Omitted: guest logs (\(reason)).")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Redacts the staged files and streams the archive into `output`. The
    /// archive root directory is `APKRun-Diagnostics-<yyyyMMdd-HHmmss>`.
    /// Returns the summary text, the compressed size, and the omissions.
    ///
    /// `onCancel` is polled between files: returning `true` abandons the run —
    /// the partial archive is truncated by the caller per runtime-api.md §4.7.
    public func write(
        bundle: DiagnosticsBundleBuilder,
        summaryContext: DiagnosticsSummaryContext,
        to output: FileHandle,
        isCancelled: () -> Bool = { false }
    ) throws -> DiagnosticsBundleResult {
        let stamp = Self.directoryStamp(options.createdAt)
        let rootName = "APKRun-Diagnostics-\(stamp)"

        // Stage every file through the redactor in a private directory.
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("apkrun-diagnostics-\(options.reportID)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: staging, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw Failure.stagingFailed(error)
        }
        defer { try? fileManager.removeItem(at: staging) }

        var entries: [(path: String, data: Data)] = []
        var omitted = bundle.omitted
        for file in bundle.files {
            if isCancelled() {
                throw CancellationError()
            }
            // The summary and manifest are added after every contributor file.
            let redactedText = redactor.redact(String(decoding: file.data, as: UTF8.self))
            let redacted = Data(redactedText.utf8)
            if redactor.containsKnownSecret(in: redacted) {
                omitted.append(
                    DiagnosticsOmittedItem(item: file.path, reason: "redactionFailed"))
                continue
            }
            // Write the staged copy so a fault leaves artifacts behind.
            let stagedPath = staging.appendingPathComponent(rootName)
                .appendingPathComponent(file.path)
            do {
                try fileManager.createDirectory(
                    at: stagedPath.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try redacted.write(to: stagedPath)
            } catch {
                throw Failure.stagingFailed(error)
            }
            entries.append((path: file.path, data: redacted))
        }

        let summaryText = Self.summary(options: options, context: summaryContext)
        entries.append(
            (
                path: "summary.txt",
                data: Data(summaryText.utf8)
            ))

        let manifest = DiagnosticsManifest(
            reportID: options.reportID,
            createdAt: ISO8601DateFormatter().string(from: options.createdAt),
            createdBy: options.createdBy,
            mode: options.mode,
            options: .init(
                includeLogcat: options.includeLogcat,
                deep: options.deep,
                focusPackage: options.focusPackage),
            build: build,
            redactionRulesVersion: Redactor.rulesVersion,
            files: entries.map {
                DiagnosticsManifestFile(
                    path: $0.path,
                    bytes: $0.data.count,
                    sha256: Self.sha256Hex($0.data))
            },
            omitted: omitted,
            redaction: redactor.redactionCounts,
            counters: [:]
        )
        let manifestData = try JSONEncoder().encode(manifest)
        entries.append((path: "manifest.json", data: manifestData))

        let zip = ZipWriter(output: output)
        for entry in entries {
            if isCancelled() {
                throw CancellationError()
            }
            do {
                try zip.addFile(name: "\(rootName)/\(entry.path)", data: entry.data)
            } catch {
                throw Failure.writeFailed(error)
            }
        }
        do {
            try zip.finish()
        } catch {
            throw Failure.writeFailed(error)
        }
        return DiagnosticsBundleResult(
            summary: summaryText,
            bytes: Int64(entries.reduce(0) { $0 + $1.data.count }),
            omitted: omitted)
    }

    /// The `yyyyMMdd-HHmmss` part of the default archive name (§8.1).
    public static func directoryStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Lower-case hex SHA-256 of `data` (manifest `files[].sha256`).
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
