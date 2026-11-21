import DiagnosticsCore
import Foundation

/// One image version the updater might apply (runtime-maintenance.md §4.3). The feed
/// fields arrive with #88; a manual install only sets `version`.
public struct ImageCandidate: Codable, Equatable, Sendable {
    /// The image version the entry installs.
    public var version: ImageVersion
    /// The feed channel the entry came from, if any.
    public var channel: String?
    /// Expected SHA-256 of the archive, lower-case hex, when the feed gave one.
    public var archiveSHA256: String?
    /// Expected archive size in bytes, when the feed gave one.
    public var archiveSize: Int64?
    /// The installed tree's size, for the space check.
    public var expandedSize: Int64?
    /// Where the archive comes from (a URL for feed entries).
    public var archiveLocation: String?
    /// Whether the entry is critical (ignores the rollout bucket).
    public var isCritical: Bool

    /// Creates a candidate.
    public init(
        version: ImageVersion,
        channel: String? = nil,
        archiveSHA256: String? = nil,
        archiveSize: Int64? = nil,
        expandedSize: Int64? = nil,
        archiveLocation: String? = nil,
        isCritical: Bool = false
    ) {
        self.version = version
        self.channel = channel
        self.archiveSHA256 = archiveSHA256
        self.archiveSize = archiveSize
        self.expandedSize = expandedSize
        self.archiveLocation = archiveLocation
        self.isCritical = isCritical
    }
}

/// The image-update phase machine (runtime-maintenance.md §4.3). The download and
/// install phases exist for #88; #59 writes `idle`, `ready`, `applying`, `failed`.
public enum ImageUpdatePhase: Equatable, Sendable {
    /// Up to date, or nothing compatible.
    case idle
    /// A check is running; transient, stored as the previous phase.
    case checking
    /// A compatible candidate exists but no download started.
    case available(ImageCandidate)
    /// A download is running (bytes done, bytes total).
    case downloading(ImageCandidate, progress: Double)
    /// An archive is being extracted and verified.
    case installing(ImageCandidate, fraction: Double)
    /// In `Images/`, not current; waiting for the apply gate.
    case ready(ImageVersion)
    /// The migration A → B is running (`RuntimeImageState.migrating`).
    case applying(from: ImageVersion, to: ImageVersion)
    /// A check, download, or install failed; `retryAt` gates the next try.
    case failed(ImageCandidate?, reason: String, retryAt: Date?)
}

/// Why a version sits on the rejected list (runtime-maintenance.md §4.8).
public enum RejectionReason: String, Codable, Equatable, Sendable {
    /// The migration health check failed (`migrationHealthFailed`).
    case migrationFailed
    /// The user went back to the previous image (`userRolledBack`).
    case userRolledBack
}

/// A rejected version and when (runtime-maintenance.md §4.8). Kept for 7 days.
public struct RejectedImage: Codable, Equatable, Sendable {
    /// The rejected version.
    public var version: ImageVersion
    /// When the rejection was recorded.
    public var at: Date
    /// Why.
    public var reason: RejectionReason
    /// The failure detail for `migrationFailed` (the health report code).
    public var detail: String?

    /// Creates a rejection record.
    public init(version: ImageVersion, at: Date, reason: RejectionReason, detail: String? = nil) {
        self.version = version
        self.at = at
        self.reason = reason
        self.detail = detail
    }
}

/// The outcome of the last `applying` phase, for `apkrun image` and Settings.
public enum ImageUpdateResult: Equatable, Sendable {
    /// The migration succeeded; `current` is this version.
    case installed(ImageVersion)
    /// The migration failed and the previous image was restored.
    case rejected(ImageVersion, reason: RejectionReason)
}

/// The persisted content of `Images/update-state.json`, schema 1. Only
/// `ImageUpdateCoordinator` writes it (runtime-maintenance.md §4.3).
public struct ImageUpdateState: Codable, Equatable, Sendable {
    /// The persisted schema version.
    public static let currentSchema = 1

    /// The schema version this state was written with.
    public var schemaVersion: Int
    /// The feed channel the state was built for (#88).
    public var channel: String
    /// When the last feed check finished.
    public var lastCheckAt: Date?
    /// When the next automatic check is due.
    public var nextCheckAt: Date?
    /// The last feed's ETag.
    public var feedETag: String?
    /// Highest accepted feed sequence per channel.
    public var acceptedSequences: [String: Int]
    /// The current candidate, if any.
    public var candidate: ImageCandidate?
    /// The persisted phase (`checking`/`installing` are stored as the phase
    /// before them, so a restart runs them again).
    public var phase: ImageUpdatePhase
    /// Rejected versions by version string (§4.8), kept 7 days.
    public var rejected: [String: RejectedImage]
    /// When the last automatic apply ran (for the daily limit).
    public var lastAutomaticApplyAt: Date?
    /// Versions the user was already notified about.
    public var notifiedVersions: [String]
    /// The outcome of the last apply.
    public var lastResult: ImageUpdateResult?

    /// Creates an empty state for `channel`.
    public init(channel: String = "stable") {
        schemaVersion = Self.currentSchema
        self.channel = channel
        lastCheckAt = nil
        nextCheckAt = nil
        feedETag = nil
        acceptedSequences = [:]
        candidate = nil
        phase = .idle
        rejected = [:]
        lastAutomaticApplyAt = nil
        notifiedVersions = []
        lastResult = nil
    }
}

// MARK: - Codable shapes

extension ImageUpdatePhase: Codable {
    private enum Kind: String, Codable {
        case idle, checking, available, downloading, installing, ready, applying, failed
    }

    /// Decodes the phase from its kind key, keeping associated values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .idle: self = .idle
        case .checking: self = .checking
        case .available:
            self = .available(try container.decode(ImageCandidate.self, forKey: .candidate))
        case .downloading:
            self = .downloading(
                try container.decode(ImageCandidate.self, forKey: .candidate),
                progress: try container.decode(Double.self, forKey: .progress)
            )
        case .installing:
            self = .installing(
                try container.decode(ImageCandidate.self, forKey: .candidate),
                fraction: try container.decode(Double.self, forKey: .progress)
            )
        case .ready:
            self = .ready(try container.decode(ImageVersion.self, forKey: .version))
        case .applying:
            self = .applying(
                from: try container.decode(ImageVersion.self, forKey: .from),
                to: try container.decode(ImageVersion.self, forKey: .version)
            )
        case .failed:
            self = .failed(
                try container.decodeIfPresent(ImageCandidate.self, forKey: .candidate),
                reason: try container.decode(String.self, forKey: .reason),
                retryAt: try container.decodeIfPresent(Date.self, forKey: .retryAt)
            )
        }
    }

    /// Encodes the phase through its kind key and associated values.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(Kind.idle, forKey: .kind)
        case .checking:
            try container.encode(Kind.checking, forKey: .kind)
        case .available(let candidate):
            try container.encode(Kind.available, forKey: .kind)
            try container.encode(candidate, forKey: .candidate)
        case .downloading(let candidate, let progress):
            try container.encode(Kind.downloading, forKey: .kind)
            try container.encode(candidate, forKey: .candidate)
            try container.encode(progress, forKey: .progress)
        case .installing(let candidate, let fraction):
            try container.encode(Kind.installing, forKey: .kind)
            try container.encode(candidate, forKey: .candidate)
            try container.encode(fraction, forKey: .progress)
        case .ready(let version):
            try container.encode(Kind.ready, forKey: .kind)
            try container.encode(version, forKey: .version)
        case .applying(let from, let to):
            try container.encode(Kind.applying, forKey: .kind)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .version)
        case .failed(let candidate, let reason, let retryAt):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encodeIfPresent(candidate, forKey: .candidate)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(retryAt, forKey: .retryAt)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, candidate, progress, version, from, reason, retryAt
    }
}

extension ImageUpdateResult: Codable {
    private enum Kind: String, Codable {
        case installed, rejected
    }

    /// Decodes the outcome: an installed version or a rejected one with its reason.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .installed:
            self = .installed(try container.decode(ImageVersion.self, forKey: .version))
        case .rejected:
            self = .rejected(
                try container.decode(ImageVersion.self, forKey: .version),
                reason: try container.decode(RejectionReason.self, forKey: .reason)
            )
        }
    }

    /// Encodes the outcome through its kind key and associated values.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .installed(let version):
            try container.encode(Kind.installed, forKey: .kind)
            try container.encode(version, forKey: .version)
        case .rejected(let version, let reason):
            try container.encode(Kind.rejected, forKey: .kind)
            try container.encode(version, forKey: .version)
            try container.encode(reason, forKey: .reason)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, version, reason
    }
}
