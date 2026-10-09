import DiagnosticsCore
import Foundation

/// One Android boot in `perf/boots.jsonl` (diagnostics.md §4.3; #014 step 1).
///
/// The markers are milliseconds from `VM_START`. The file holds one JSON object per line, and
/// the newest `BootRecordLog.retainedRecordCount` records are kept.
public struct BootRecord: Codable, Equatable, Sendable {
    /// The schema version of the perf records (runtime-maintenance.md §5).
    public var v: Int
    /// When the record was written, in UTC.
    public var recordedAt: Date
    /// The boot's identifier, also in the boot log (`Prepared boot <id>`).
    public var operationID: UUID
    /// `cold` for an instance that was ready before, `firstBoot` for the provisioning boot.
    public var bootKind: String
    /// The image version the boot used.
    public var image: String
    /// The GPU profile (`headless` in M1).
    public var gpuProfile: String
    /// The guest memory in GiB.
    public var memoryGiB: Int
    /// The guest vCPU count.
    public var cpuCount: Int
    /// Markers in milliseconds from `VM_START`, keyed by the marker name.
    public var markers: [String: Double]
    /// `ready`, `stopped`, or `failed:<error code>`.
    public var outcome: String

    /// Creates a record. `v` is the schema version.
    public init(
        recordedAt: Date,
        operationID: UUID,
        bootKind: String,
        image: String,
        gpuProfile: String,
        memoryGiB: Int,
        cpuCount: Int,
        markers: [String: Double],
        outcome: String
    ) {
        v = 1
        self.recordedAt = recordedAt
        self.operationID = operationID
        self.bootKind = bootKind
        self.image = image
        self.gpuProfile = gpuProfile
        self.memoryGiB = memoryGiB
        self.cpuCount = cpuCount
        self.markers = markers
        self.outcome = outcome
    }
}

/// Encodes and retains the boot records of `perf/boots.jsonl`.
public enum BootRecordLog {
    /// The newest records kept in the file (configuration.md §4, `boots.jsonl` newest 200).
    public static let retainedRecordCount = 200

    /// The one-line JSON encoding of `record`, with sorted keys and whole-second UTC dates.
    public static func line(for record: BootRecord) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(record), as: UTF8.self)
    }

    /// The newest `limit` of `lines`, in their original order.
    public static func retainNewest(_ lines: [String], limit: Int = retainedRecordCount) -> [String] {
        lines.count > limit ? Array(lines.suffix(limit)) : lines
    }

    /// Appends `record` to `url` and keeps the newest records, replacing the file atomically.
    public static func append(_ record: BootRecord, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let existing: [String]
        if FileManager.default.fileExists(atPath: url.path) {
            existing = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        } else {
            existing = []
        }
        let lines = retainNewest(existing + [try line(for: record)])
        let text = lines.joined(separator: "\n") + "\n"
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temporary, options: .withoutOverwriting)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
