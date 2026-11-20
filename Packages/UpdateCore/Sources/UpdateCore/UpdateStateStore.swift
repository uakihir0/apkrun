import APKStoreCore
import Foundation

// `Updates/state.json` and `Updates/history.jsonl` (update-system.md §10).

/// What triggered an update run (history `trigger`, runtime-api.md §9.2).
public enum UpdateTrigger: String, Codable, Sendable {
    /// A scheduled check.
    case scheduled
    /// The user asked for the check.
    case userInitiated
    /// A manual file update.
    case manual
    /// A check after the package's session opened.
    case launchOpportunistic
}

/// The per-package row of `Updates/state.json` (update-system.md §10.1).
public struct PackageUpdateState: Codable, Sendable, Equatable {
    /// When the last check ran.
    public var lastCheckAt: Date?
    /// When a session's first frame was counted as the install's H4
    /// (update-system.md §7.2): the session waited on a committing
    /// install, then launched the new version itself.
    public var postUpdateFirstFrameAt: Date?
    /// When the package is next due.
    public var nextCheckAt: Date?
    /// Checks that failed in a row; resets on success.
    public var consecutiveFailures: Int
    /// The cursor of the candidate processed last (§4.2).
    public var cursor: ProviderCursor?
    /// The persisted phase; only "available" and "staged" survive a restart.
    public var phase: String?
    /// A summary of the current candidate.
    public var candidate: CandidateSummary?
    /// When the current staged set was written.
    public var stagedAt: Date?
    /// When the "waiting too long" notice was posted (§7.4).
    public var waitingNotifiedAt: Date?
    /// Versions the user skipped (§8.4).
    public var skippedVersions: [VersionCode]
    /// The last update-available notification's cursor, so it posts once.
    public var notifiedCursor: ProviderCursor?

    /// A compact candidate description persisted in state.json.
    public struct CandidateSummary: Codable, Sendable, Equatable {
        /// The declared versionCode.
        public var versionCode: VersionCode?
        /// The declared versionName.
        public var versionName: String?
        /// The provider type that offered it.
        public var provider: ProviderType
        /// The expected signing identities, so a gate-resumed install can
        /// still run H1's signer comparison (update-system.md §8.1).
        public var signerDigests: [SHA256Digest]?
        /// The provider cursor to save once the install completes.
        public var cursor: ProviderCursor?
        /// §7.3 "Update Now" ended the package's session; a successful
        /// install reopens it (persists so a gate-resumed install
        /// reopens too).
        public var reopenAfterInstall: Bool

        /// Creates a summary.
        public init(
            versionCode: VersionCode?,
            versionName: String?,
            provider: ProviderType,
            signerDigests: [SHA256Digest]? = nil,
            cursor: ProviderCursor? = nil,
            reopenAfterInstall: Bool = false
        ) {
            self.versionCode = versionCode
            self.versionName = versionName
            self.provider = provider
            self.signerDigests = signerDigests
            self.cursor = cursor
            self.reopenAfterInstall = reopenAfterInstall
        }

        /// Decodes a summary, tolerating rows written before
        /// `reopenAfterInstall` existed (§7.3, added later).
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            versionCode = try container.decodeIfPresent(VersionCode.self, forKey: .versionCode)
            versionName = try container.decodeIfPresent(String.self, forKey: .versionName)
            provider = try container.decode(ProviderType.self, forKey: .provider)
            signerDigests = try container.decodeIfPresent(
                [SHA256Digest].self, forKey: .signerDigests)
            cursor = try container.decodeIfPresent(ProviderCursor.self, forKey: .cursor)
            reopenAfterInstall =
                try container.decodeIfPresent(Bool.self, forKey: .reopenAfterInstall) ?? false
        }
    }

    /// Creates an empty state row.
    public init(
        lastCheckAt: Date? = nil,
        nextCheckAt: Date? = nil,
        consecutiveFailures: Int = 0,
        cursor: ProviderCursor? = nil,
        phase: String? = nil,
        candidate: CandidateSummary? = nil,
        stagedAt: Date? = nil,
        waitingNotifiedAt: Date? = nil,
        skippedVersions: [VersionCode] = [],
        notifiedCursor: ProviderCursor? = nil
    ) {
        self.lastCheckAt = lastCheckAt
        self.nextCheckAt = nextCheckAt
        self.consecutiveFailures = consecutiveFailures
        self.cursor = cursor
        self.phase = phase
        self.candidate = candidate
        self.stagedAt = stagedAt
        self.waitingNotifiedAt = waitingNotifiedAt
        self.skippedVersions = skippedVersions
        self.notifiedCursor = notifiedCursor
    }
}

/// One `Updates/history.jsonl` line (update-system.md §10.2, schema `v` = 1).
public struct UpdateHistoryEntry: Codable, Sendable, Equatable {
    /// The schema version.
    public var v: Int
    /// When the run ended.
    public var time: Date
    /// The package the run covered.
    public var packageID: PackageID
    /// The installed versionCode before the run.
    public var from: VersionCode?
    /// The versionCode the run installed or offered.
    public var to: VersionCode?
    /// The provider used.
    public var provider: ProviderType?
    /// What triggered the run.
    public var trigger: UpdateTrigger
    /// The run outcome ("available", "updated", "skipped.upToDate", …).
    public var outcome: String
    /// The error code of a failed run.
    public var failure: String?
    /// Milliseconds spent per phase.
    public var phaseDurationsMs: [String: Int]

    /// Creates a history entry.
    public init(
        time: Date,
        packageID: PackageID,
        from: VersionCode?,
        to: VersionCode?,
        provider: ProviderType?,
        trigger: UpdateTrigger,
        outcome: String,
        failure: String? = nil,
        phaseDurationsMs: [String: Int] = [:]
    ) {
        self.v = 1
        self.time = time
        self.packageID = packageID
        self.from = from
        self.to = to
        self.provider = provider
        self.trigger = trigger
        self.outcome = outcome
        self.failure = failure
        self.phaseDurationsMs = phaseDurationsMs
    }
}

/// The atomic, coalesced writer of `Updates/state.json` and the append-only
/// `Updates/history.jsonl` (update-system.md §10). Missing or unreadable files
/// rebuild empty, so every package is due again.
public actor UpdateStateStore {
    /// The full `state.json` document.
    public struct State: Codable, Sendable, Equatable {
        /// The schema version.
        public var schemaVersion: Int
        /// Per-package state rows.
        public var packages: [PackageID: PackageUpdateState]

        /// Creates an empty state document.
        public init(schemaVersion: Int = 1, packages: [PackageID: PackageUpdateState] = [:]) {
            self.schemaVersion = schemaVersion
            self.packages = packages
        }
    }

    /// Retention for history.jsonl: 365 days or 5 000 lines, whichever is less.
    static let historyMaximumAge: TimeInterval = 365 * 24 * 60 * 60
    static let historyMaximumLines = 5_000

    private let directory: URL
    private let fileManager = FileManager.default
    /// The minimum interval between state.json writes (§10.1 coalescing).
    private let writeInterval: TimeInterval
    private var state: State
    private var dirty = false
    private var writeTask: Task<Void, Never>?

    /// Opens (or creates) the store under `Updates/` at `directory`.
    public init(directory: URL, writeInterval: TimeInterval = 1) {
        self.directory = directory
        self.writeInterval = writeInterval
        let stateFile = directory.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateFile),
            let decoded = try? Self.decoder.decode(State.self, from: data)
        {
            state = decoded
        } else {
            state = State()
        }
    }

    /// Returns the state row of a package, nil when it was never tracked.
    public func state(for packageID: PackageID) -> PackageUpdateState? {
        state.packages[packageID]
    }

    /// Returns every package's state row.
    public func allStates() -> [PackageID: PackageUpdateState] {
        state.packages
    }

    /// Mutates a package's state row and schedules a coalesced write.
    public func update(
        _ packageID: PackageID,
        _ transform: @Sendable (inout PackageUpdateState) -> Void
    ) async {
        var row = state.packages[packageID] ?? PackageUpdateState()
        transform(&row)
        state.packages[packageID] = row
        scheduleWrite()
    }

    /// Replaces the whole state and schedules a coalesced write.
    public func replaceAll(_ newState: State) {
        state = newState
        scheduleWrite()
    }

    /// Writes pending changes now (at most every `writeInterval` normally).
    public func flush() async {
        writeTask?.cancel()
        writeTask = nil
        await writeNow()
    }

    private func scheduleWrite() {
        dirty = true
        guard writeTask == nil else { return }
        let interval = writeInterval
        writeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard let self else { return }
            await self.writeNow()
        }
    }

    private func writeNow() async {
        guard dirty else { return }
        dirty = false
        let stateFile = directory.appendingPathComponent("state.json")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(state)
            try data.write(to: stateFile, options: .atomic)
        } catch {
            // A failed write retries on the next mutation; mark dirty again.
            dirty = true
        }
    }

    /// Appends one history line; the file is pruned to its retention limits.
    public func appendHistory(_ entry: UpdateHistoryEntry) async throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let historyFile = directory.appendingPathComponent("history.jsonl")
        let data = try Self.encoder.encode(entry)
        if let handle = try? FileHandle(forWritingTo: historyFile) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data([0x0A]))
        } else {
            try (data + Data([0x0A])).write(to: historyFile)
        }
        try pruneHistory(historyFile)
    }

    /// Returns the stored history entries, oldest first.
    public func history(packageID: PackageID? = nil, limit: Int = 50) throws -> [UpdateHistoryEntry] {
        let historyFile = directory.appendingPathComponent("history.jsonl")
        guard let data = try? Data(contentsOf: historyFile) else { return [] }
        var entries: [UpdateHistoryEntry] = []
        for line in data.split(separator: 0x0A) {
            guard let entry = try? Self.decoder.decode(UpdateHistoryEntry.self, from: Data(line)),
                packageID == nil || entry.packageID == packageID
            else { continue }
            entries.append(entry)
        }
        return Array(entries.suffix(min(max(limit, 0), 1_000)))
    }

    private func pruneHistory(_ historyFile: URL) throws {
        guard let data = try? Data(contentsOf: historyFile) else { return }
        let lines = data.split(separator: 0x0A)
        let cutoff = Date().addingTimeInterval(-Self.historyMaximumAge)
        var kept = lines.filter { line in
            guard let entry = try? Self.decoder.decode(UpdateHistoryEntry.self, from: Data(line))
            else { return true }
            return entry.time >= cutoff
        }
        if kept.count > Self.historyMaximumLines {
            kept = Array(kept.suffix(Self.historyMaximumLines))
        }
        if kept.count != lines.count {
            let pruned = kept.joined(separator: [0x0A]) + [0x0A]
            try Data(pruned).write(to: historyFile)
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
