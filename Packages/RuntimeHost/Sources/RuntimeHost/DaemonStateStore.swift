import Darwin
import Foundation

/// The persisted summary of one Android boot for the daemon progress estimate.
public struct DaemonBootHistory: Codable, Equatable, Sendable {
    /// When the boot reached runtime-ready.
    public let recordedAt: Date
    /// The image version used by the boot.
    public let imageVersion: String
    /// `cold` or `firstBoot`.
    public let kind: String
    /// Phase and marker durations in milliseconds from `VM_START`.
    public let phasesMs: [String: Int]

    /// Creates a compact boot history entry.
    public init(
        recordedAt: Date = Date(),
        imageVersion: String,
        kind: String,
        phasesMs: [String: Int]
    ) {
        self.recordedAt = recordedAt
        self.imageVersion = imageVersion
        self.kind = kind
        self.phasesMs = phasesMs
    }
}

/// The daemon's crash and boot history stored in `Runtime/daemon.json`.
public struct DaemonStateRecord: Codable, Equatable, Sendable {
    /// The supported record schema.
    public let schemaVersion: Int
    /// The current daemon PID.
    public var pid: Int32
    /// When this process started.
    public var startedAt: Date
    /// The APKRun version and build.
    public var version: String
    /// Set only after graceful shutdown finishes.
    public var cleanExit: Bool
    /// The newest unclean daemon exits.
    public var recentUncleanExits: [Date]
    /// The newest failed Android boots.
    public var recentFailedBoots: [Date]
    /// The newest boot measurements used for progress estimates.
    public var bootHistory: [DaemonBootHistory]

    /// Creates a schema version 1 record.
    public init(
        pid: Int32,
        startedAt: Date,
        version: String,
        cleanExit: Bool,
        recentUncleanExits: [Date] = [],
        recentFailedBoots: [Date] = [],
        bootHistory: [DaemonBootHistory] = []
    ) {
        schemaVersion = 1
        self.pid = pid
        self.startedAt = startedAt
        self.version = version
        self.cleanExit = cleanExit
        self.recentUncleanExits = recentUncleanExits
        self.recentFailedBoots = recentFailedBoots
        self.bootHistory = bootHistory
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case pid
        case startedAt
        case version
        case cleanExit
        case recentUncleanExits
        case recentFailedBoots
        case bootHistory
    }

    /// Decodes a persisted record and defaults fields added after schema version 1.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        pid = try values.decode(Int32.self, forKey: .pid)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        version = try values.decode(String.self, forKey: .version)
        cleanExit = try values.decode(Bool.self, forKey: .cleanExit)
        recentUncleanExits = try values.decodeIfPresent([Date].self, forKey: .recentUncleanExits) ?? []
        recentFailedBoots = try values.decodeIfPresent([Date].self, forKey: .recentFailedBoots) ?? []
        bootHistory = try values.decodeIfPresent([DaemonBootHistory].self, forKey: .bootHistory) ?? []
    }
}

/// The startup facts derived from the previous daemon record.
public struct DaemonStartupAssessment: Equatable, Sendable {
    /// Whether the previous daemon record proves that the process exited without cleaning up.
    public let previousExitWasUnclean: Bool
    /// Whether three unclean exits occurred within the ten minute crash-loop window.
    public let crashLoopActive: Bool
    /// The record written for this process.
    public let record: DaemonStateRecord
}

/// Persistence errors for `Runtime/daemon.json`.
public enum DaemonStateStoreError: Error, Equatable, Sendable {
    /// The record could not be decoded.
    case unreadable(domain: String, code: Int)
    /// The record was written by a newer daemon that this binary cannot safely overwrite.
    case unsupportedSchema(version: Int)
    /// The current daemon record was missing or belonged to another process.
    case currentRunMismatch
    /// A file-system operation failed.
    case storage(domain: String, code: Int)
}

/// Reads and atomically updates the daemon lifecycle record.
public struct DaemonStateStore: Sendable {
    /// The number of unclean exits that activates the boot guard.
    public static let crashLoopThreshold = 3
    /// The window used by the automatic boot guard.
    public static let crashLoopWindow: TimeInterval = 10 * 60
    /// The number of recent boot summaries retained in `daemon.json`.
    public static let retainedBootHistory = 25
    /// The number of recent unclean exits retained in `daemon.json`.
    public static let retainedUncleanExits = 10
    /// The number of failed Android boots that activates the automatic boot guard.
    public static let failedBootThreshold = 3

    private let fileURL: URL

    /// Creates a store for the daemon record.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Records the current daemon as running and assesses an unclean prior exit.
    public func beginRun(
        pid: Int32 = getpid(),
        version: String,
        now: Date = Date()
    ) throws(DaemonStateStoreError) -> DaemonStartupAssessment {
        let previous = try read()
        // The caller takes InstanceLock before opening the state store. If that lock is available,
        // no prior apkrund still owns the runtime; checking the old PID would misclassify an
        // unrelated process that reused the PID after a crash as the old daemon.
        let previousExitWasUnclean = previous.map { !$0.cleanExit } ?? false
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        var uncleanExits = previous?.recentUncleanExits.filter { $0 >= cutoff } ?? []
        let failedBoots = previous?.recentFailedBoots.filter { $0 >= cutoff } ?? []
        if previousExitWasUnclean {
            uncleanExits.append(now)
        }
        if uncleanExits.count > Self.retainedUncleanExits {
            uncleanExits = Array(uncleanExits.suffix(Self.retainedUncleanExits))
        }

        let record = DaemonStateRecord(
            pid: pid,
            startedAt: now,
            version: version,
            cleanExit: false,
            recentUncleanExits: uncleanExits,
            recentFailedBoots: failedBoots,
            bootHistory: previous?.bootHistory ?? []
        )
        try write(record)
        return DaemonStartupAssessment(
            previousExitWasUnclean: previousExitWasUnclean,
            crashLoopActive: Self.isGuardActive(
                uncleanExits,
                recentFailedBoots: failedBoots,
                now: now
            ),
            record: record
        )
    }

    /// Marks the current process as cleanly exited.
    public func markCleanExit(pid: Int32 = getpid()) throws(DaemonStateStoreError) {
        guard var record = try read(), record.pid == pid, !record.cleanExit else {
            throw .currentRunMismatch
        }
        record.cleanExit = true
        try write(record)
    }

    /// Clears both automatic boot guards after an explicit user start request.
    public func clearBootLoopGuard(pid: Int32 = getpid()) throws(DaemonStateStoreError) {
        guard var record = try read(), record.pid == pid, !record.cleanExit else {
            throw .currentRunMismatch
        }
        record.recentUncleanExits.removeAll()
        record.recentFailedBoots.removeAll()
        try write(record)
    }

    /// Records a failed Android boot for the persistent automatic boot guard.
    public func recordFailedBoot(
        at date: Date = Date(),
        pid: Int32 = getpid()
    ) throws(DaemonStateStoreError) {
        guard var record = try read(), record.pid == pid, !record.cleanExit else {
            throw .currentRunMismatch
        }
        let cutoff = date.addingTimeInterval(-24 * 60 * 60)
        record.recentFailedBoots = record.recentFailedBoots.filter { $0 >= cutoff }
        record.recentFailedBoots.append(date)
        if record.recentFailedBoots.count > Self.retainedUncleanExits {
            record.recentFailedBoots = Array(record.recentFailedBoots.suffix(Self.retainedUncleanExits))
        }
        try write(record)
    }

    /// Clears failed boot attempts after Android boots successfully.
    public func clearFailedBootHistory(pid: Int32 = getpid()) throws(DaemonStateStoreError) {
        guard var record = try read(), record.pid == pid, !record.cleanExit else {
            throw .currentRunMismatch
        }
        record.recentFailedBoots.removeAll()
        try write(record)
    }

    /// Whether either persistent guard has reached its independent threshold.
    public func bootLoopGuardIsActive(
        now: Date = Date()
    ) throws(DaemonStateStoreError) -> Bool {
        guard let record = try read() else { return false }
        return Self.isGuardActive(
            record.recentUncleanExits,
            recentFailedBoots: record.recentFailedBoots,
            now: now
        )
    }

    /// Adds a boot summary while preserving the current daemon run and crash history.
    public func appendBootHistory(_ boot: DaemonBootHistory) throws(DaemonStateStoreError) {
        guard var record = try read() else {
            throw .currentRunMismatch
        }
        record.bootHistory.append(boot)
        if record.bootHistory.count > Self.retainedBootHistory {
            record.bootHistory = Array(record.bootHistory.suffix(Self.retainedBootHistory))
        }
        try write(record)
    }

    /// Reads the current record, if one exists.
    public func current() throws(DaemonStateStoreError) -> DaemonStateRecord? {
        try read()
    }

    private func read() throws(DaemonStateStoreError) -> DaemonStateRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(DaemonStateRecord.self, from: Data(contentsOf: fileURL))
            guard record.schemaVersion == 1 else {
                throw DaemonStateStoreError.unsupportedSchema(version: record.schemaVersion)
            }
            return record
        } catch let error as DaemonStateStoreError {
            throw error
        } catch {
            let error = error as NSError
            throw .unreadable(domain: error.domain, code: error.code)
        }
    }

    private func write(_ record: DaemonStateRecord) throws(DaemonStateStoreError) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: fileURL, options: .atomic)
            guard chmod(fileURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        } catch {
            let error = error as NSError
            throw .storage(domain: error.domain, code: error.code)
        }
    }

    private static func isGuardActive(
        _ recentUncleanExits: [Date],
        recentFailedBoots: [Date] = [],
        now: Date
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.crashLoopWindow)
        return recentUncleanExits.filter { $0 >= cutoff }.count >= Self.crashLoopThreshold
            || recentFailedBoots.filter { $0 >= cutoff }.count >= Self.failedBootThreshold
    }
}
