import DiagnosticsCore
import Foundation
import RuntimeAPI

/// One app launch in `perf/launches.jsonl` (diagnostics.md §4.3).
///
/// Markers are milliseconds relative to `WRAPPER_PROCESS_START` — the launcher's
/// own base stamp — when `OpenSessionRequest.launchTiming` arrived, else the
/// launch request's arrival at the daemon.
public struct LaunchRecord: Codable, Equatable, Sendable {
    /// The record format version; always 1.
    public var v: Int
    /// When the record was finalized, in UTC.
    public var recordedAt: Date
    /// The launched package.
    public var packageID: String
    /// The installed version code, when known.
    public var versionCode: Int64?
    /// The session opened for the launch.
    public var sessionID: String?
    /// The launch operation's identifier.
    public var operationID: String?
    /// `hot`, `warm`, `suspended`, `cold`, or `firstBoot` (§4.3 table).
    public var launchState: String
    /// `secondaryDisplay`, `primaryDisplay`, or `windowed`.
    public var windowMode: String
    /// The APKRun build number.
    public var build: String
    /// The Android image version in use.
    public var image: String
    /// The GPU profile.
    public var gpuProfile: String
    /// Markers in milliseconds from the record base, keyed by marker name.
    public var markers: [String: Double]
    /// `FIRST_FRAME_DISPLAYED` minus the base, or the end point when it never came.
    public var totalMs: Double
    /// `shown`, `ended(<reason>)`, or `failed(<code>)`.
    public var outcome: String

    /// Creates a launch record.
    public init(
        recordedAt: Date = Date(),
        packageID: String,
        versionCode: Int64? = nil,
        sessionID: String? = nil,
        operationID: String? = nil,
        launchState: String,
        windowMode: String,
        build: String,
        image: String,
        gpuProfile: String,
        markers: [String: Double],
        totalMs: Double,
        outcome: String
    ) {
        v = 1
        self.recordedAt = recordedAt
        self.packageID = packageID
        self.versionCode = versionCode
        self.sessionID = sessionID
        self.operationID = operationID
        self.launchState = launchState
        self.windowMode = windowMode
        self.build = build
        self.image = image
        self.gpuProfile = gpuProfile
        self.markers = markers
        self.totalMs = totalMs
        self.outcome = outcome
    }
}

/// Appends launch records to `perf/launches.jsonl`, keeping the newest 2,000
/// (diagnostics.md §3.3, §4.3). Boot records live in `BootRecordLog`
/// (RuntimeCore); `enforceLimits` trims both files atomically at apkrund start.
public final class PerfRecordWriter: @unchecked Sendable {
    /// The launch record cap (§3.3).
    public static let launchLimit = 2_000
    /// The boot record cap.
    public static let bootLimit = 200

    private let launchFile: URL
    private let bootFile: URL
    private let lock = NSLock()

    /// Creates a writer for the paths' perf directory.
    public init(paths: APKRunPaths) {
        launchFile = paths.launchPerformanceFile
        bootFile = paths.bootPerformanceFile
    }

    /// Creates a writer against explicit files (tests).
    public init(launchFile: URL, bootFile: URL) {
        self.launchFile = launchFile
        self.bootFile = bootFile
    }

    /// Trims both record files to their caps, atomically, at apkrund start (§4.3).
    public func enforceLimits() {
        lock.withLock {
            Self.trim(launchFile, to: Self.launchLimit)
            Self.trim(bootFile, to: Self.bootLimit)
        }
    }

    /// Appends a launch record; never fails — a record write must not break the
    /// launch it measures (§4.1).
    public func appendLaunch(_ record: LaunchRecord) {
        lock.withLock {
            Self.append(Self.line(for: record), to: launchFile)
            Self.trim(launchFile, to: Self.launchLimit)
        }
    }

    /// The one-line JSON encoding of `record`, sorted keys (tests).
    public static func line(for record: LaunchRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads back the stored launch records (tests and `apkrun-perf`).
    public func launchRecords() -> [LaunchRecord] {
        lock.withLock { Self.read(from: launchFile) }
    }

    /// Reads valid launch records from a file.
    public static func read(from url: URL) -> [LaunchRecord] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(LaunchRecord.self, from: Data($0.utf8)) }
    }

    private static func append(_ line: String, to file: URL) {
        guard !line.isEmpty else {
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(line.utf8 + [0x0A])
            if FileManager.default.fileExists(atPath: file.path) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        } catch {
            // Recording must never break the measured operation (§4.1).
        }
    }

    /// Keeps the newest `limit` lines via an atomic temporary-file rewrite (§4.3).
    private static func trim(_ file: URL, to limit: Int) {
        guard let data = try? Data(contentsOf: file) else {
            return
        }
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard lines.count > limit else {
            return
        }
        lines = Array(lines.suffix(limit))
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
