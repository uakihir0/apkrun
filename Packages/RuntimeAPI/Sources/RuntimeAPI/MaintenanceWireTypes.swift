import Foundation

/// The daemon lifecycle state published by the maintenance surface
/// (runtime-maintenance.md §3.6, runtime-api.md §3.7).
public enum HostState: Codable, Equatable, Sendable {
    /// Normal operation.
    case normal
    /// A coordinated APKRun update is being installed; most operations fail
    /// with `runtime.hostUpdating`.
    case updating(targetBuild: Int)
    /// The bundle on disk was replaced while apkrund was running. Bundle
    /// resource readers fail until apkrund exits and launchd starts the new one.
    case restartPending(bundleBuild: Int?)
    /// A host state added by a newer build.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
    }

    /// Decodes a known host state, preserving a future state as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one host state case.")
            )
        }
        switch key.stringValue {
        case "normal":
            self = .normal
        case "updating":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .updating(targetBuild: try payload.decode(Int.self, forKey: .first))
        case "restartPending":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .restartPending(bundleBuild: try payload.decodeIfPresent(Int.self, forKey: .first))
        case "unknown":
            self = .unknown
        default:
            self = .unknown
        }
    }

    /// Encodes a known host state.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .normal:
            Self.encodeEmpty("normal", into: &container)
        case .updating(let targetBuild):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("updating"))
            try payload.encode(targetBuild, forKey: .first)
        case .restartPending(let bundleBuild):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("restartPending"))
            try payload.encodeIfPresent(bundleBuild, forKey: .first)
        case .unknown:
            Self.encodeEmpty("unknown", into: &container)
        }
    }

    private static func encodeEmpty(
        _ caseName: String,
        into container: inout KeyedEncodingContainer<RuntimeEventCodingKey>
    ) {
        _ = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey(caseName))
    }
}

/// The host-update marker written to `Runtime/maintenance.json`
/// (runtime-maintenance.md §3.6).
public struct HostUpdateMarker: Codable, Equatable, Sendable {
    /// The schema version of the marker file.
    public let schemaVersion: Int
    /// The marketing version apkrund is updating from.
    public let fromVersion: String
    /// The build apkrund is updating from.
    public let fromBuild: Int
    /// The marketing version being installed.
    public let targetVersion: String
    /// The build being installed.
    public let targetBuild: Int
    /// When the marker was written.
    public let createdAt: Date
    /// The coordination operation that wrote the marker.
    public let operationID: UUID

    /// The current marker schema.
    public static let currentSchemaVersion = 1

    /// Creates a marker.
    public init(
        fromVersion: String,
        fromBuild: Int,
        targetVersion: String,
        targetBuild: Int,
        createdAt: Date,
        operationID: UUID
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.fromVersion = fromVersion
        self.fromBuild = fromBuild
        self.targetVersion = targetVersion
        self.targetBuild = targetBuild
        self.createdAt = createdAt
        self.operationID = operationID
    }
}

/// The maintenance endpoint's status snapshot (runtime-api.md §12.1).
public struct MaintenanceStatus: Codable, Equatable, Sendable {
    /// The marketing version of the running apkrund.
    public let version: String
    /// The build number of the running apkrund.
    public let build: Int
    /// The daemon lifecycle state.
    public let hostState: HostState
    /// Packages with an open session.
    public let sessions: [RuntimePackageID]
    /// Packages with a `keepRunning` background task.
    public let backgroundTasks: [RuntimePackageID]
    /// Activities that keep apkrund awake.
    public let activities: [ActivityKind]
    /// Whether an Android image migration is running.
    public let imageMigrating: Bool
    /// The host-update marker on disk, when present.
    public let marker: HostUpdateMarker?

    /// Creates a status snapshot.
    public init(
        version: String,
        build: Int,
        hostState: HostState,
        sessions: [RuntimePackageID],
        backgroundTasks: [RuntimePackageID],
        activities: [ActivityKind],
        imageMigrating: Bool,
        marker: HostUpdateMarker? = nil
    ) {
        self.version = version
        self.build = build
        self.hostState = hostState
        self.sessions = sessions
        self.backgroundTasks = backgroundTasks
        self.activities = activities
        self.imageMigrating = imageMigrating
        self.marker = marker
    }
}

/// The coordinated install request of runtime-maintenance.md §3.5 step 4.
public struct HostUpdateRequest: Codable, Equatable, Sendable {
    /// The marketing version being installed.
    public let targetVersion: String
    /// The build being installed.
    public let targetBuild: Int
    /// Whether apkrund may end open sessions. False with open sessions returns
    /// `maintenance.hostUpdateSessionsOpen`.
    public let closeSessions: Bool

    /// Creates a host-update request.
    public init(targetVersion: String, targetBuild: Int, closeSessions: Bool) {
        self.targetVersion = targetVersion
        self.targetBuild = targetBuild
        self.closeSessions = closeSessions
    }
}

/// The restart request for `restartPending` (runtime-api.md §12.1).
public struct RestartForUpdateRequest: Codable, Equatable, Sendable {
    /// Whether apkrund may end open sessions. False with open sessions returns
    /// `maintenance.hostUpdateSessionsOpen`.
    public let closeSessions: Bool

    /// Creates a restart request.
    public init(closeSessions: Bool) {
        self.closeSessions = closeSessions
    }
}

/// One appcast item the self-update probe selected (runtime-api.md §12.2).
public struct AvailableRelease: Codable, Equatable, Sendable {
    /// The item's marketing version (`sparkle:shortVersionString`).
    public let version: String
    /// The item's build number (`sparkle:version`).
    public let build: Int
    /// The item's channel, when the appcast declares one.
    public let channel: String?
    /// The item's minimum macOS version, when declared.
    public let minimumSystemVersion: String?
    /// The release notes URL, when declared.
    public let releaseNotesURL: String?
    /// The item's publication date.
    public let publishedAt: Date?

    /// Creates an available release.
    public init(
        version: String,
        build: Int,
        channel: String? = nil,
        minimumSystemVersion: String? = nil,
        releaseNotesURL: String? = nil,
        publishedAt: Date? = nil
    ) {
        self.version = version
        self.build = build
        self.channel = channel
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotesURL = releaseNotesURL
        self.publishedAt = publishedAt
    }
}

/// The self-update probe's snapshot (runtime-maintenance.md §3.4).
public struct SelfUpdateStatus: Codable, Equatable, Sendable {
    /// The running build's marketing version.
    public let currentVersion: String
    /// The running build's build number.
    public let currentBuild: Int
    /// The newest release the probe accepts, when one is newer than this build.
    public let latest: AvailableRelease?
    /// Whether `latest` is a critical update.
    public let critical: Bool
    /// When the probe last finished a check.
    public let lastCheckedAt: Date?
    /// The last check's error, when it failed.
    public let lastError: WireError?
    /// Whether Sparkle has a downloaded update that installs on quit.
    public let pendingOnQuit: Bool

    /// Creates a self-update snapshot.
    public init(
        currentVersion: String,
        currentBuild: Int,
        latest: AvailableRelease? = nil,
        critical: Bool = false,
        lastCheckedAt: Date? = nil,
        lastError: WireError? = nil,
        pendingOnQuit: Bool = false
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.latest = latest
        self.critical = critical
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
        self.pendingOnQuit = pendingOnQuit
    }
}

/// A user-initiated probe check request (runtime-api.md §12.2).
public struct CheckSelfUpdateRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// Whether a user asked for the check; phased rollout is ignored then.
    public let userInitiated: Bool

    /// Creates a check request.
    public init(header: APIRequestHeader, userInitiated: Bool) {
        self.header = header
        self.userInitiated = userInitiated
    }
}

/// APKRun.app's report of Sparkle's result to apkrund (runtime-api.md §12.2).
public struct SelfUpdateNote: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The release Sparkle found, when newer than the current build.
    public let found: AvailableRelease?
    /// Whether Sparkle holds a downloaded update for quit.
    public let pendingOnQuit: Bool
    /// When Sparkle finished the check.
    public let checkedAt: Date

    /// Creates a self-update note.
    public init(header: APIRequestHeader, found: AvailableRelease?, pendingOnQuit: Bool, checkedAt: Date) {
        self.header = header
        self.found = found
        self.pendingOnQuit = pendingOnQuit
        self.checkedAt = checkedAt
    }
}

/// A self-update status request on the control endpoint (runtime-api.md §12.2).
public struct SelfUpdateStatusRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader

    /// Creates a status request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// A self-update status reply (runtime-api.md §12.2).
public struct SelfUpdateStatusReply: Codable, Equatable, Sendable {
    /// The snapshot on success.
    public var result: SelfUpdateStatus?
    /// The structured failure, present when the request was rejected.
    public var error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: SelfUpdateStatus) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The `noteSelfUpdateStatus` reply (runtime-api.md §12.2).
public struct SelfUpdateNoteReply: Codable, Equatable, Sendable {
    /// The empty success body.
    public var result: RuntimeEmpty?
    /// The failure on error.
    public var error: RuntimeWireError?

    /// Creates a note reply.
    public init(result: RuntimeEmpty? = nil, error: RuntimeWireError? = nil) {
        self.result = result
        self.error = error
    }
}

/// A maintenance status reply (runtime-api.md §12.1).
public struct MaintenanceStatusReply: Codable, Equatable, Sendable {
    /// The snapshot on success.
    public var result: MaintenanceStatus?
    /// The structured failure, present when the request was rejected.
    public var error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: MaintenanceStatus) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// Requests on the frozen maintenance endpoint (runtime-api.md §12.1).
public enum MaintenanceControlOperation: String, Codable, Equatable, Sendable {
    /// Status snapshot.
    case maintenanceStatus
    /// The coordinated install of §3.5 step 4.
    case prepareForHostUpdate
    /// Delete the marker and return to `normal`.
    case abortHostUpdate
    /// End the finishing wait of §3.6.
    case completeHostUpdate
    /// Restart in `restartPending`.
    case restartForUpdate
}

/// The frozen maintenance endpoint's request envelope. It has no API version:
/// the protocol is additive-only, so any two builds can coordinate an update
/// (runtime-maintenance.md §8.1).
public struct MaintenanceControlRequest: Codable, Equatable, Sendable {
    /// The request metadata; the server ignores its version.
    public let header: APIRequestHeader
    /// The operation to run.
    public let operation: MaintenanceControlOperation
    /// The `prepareForHostUpdate` payload, when the operation needs one.
    public let hostUpdate: HostUpdateRequest?
    /// The `restartForUpdate` payload, when the operation needs one.
    public let restart: RestartForUpdateRequest?

    /// Creates a request.
    public init(
        header: APIRequestHeader,
        operation: MaintenanceControlOperation,
        hostUpdate: HostUpdateRequest? = nil,
        restart: RestartForUpdateRequest? = nil
    ) {
        self.header = header
        self.operation = operation
        self.hostUpdate = hostUpdate
        self.restart = restart
    }
}

/// The frozen maintenance endpoint's reply envelope.
public struct MaintenanceControlReply: Codable, Equatable, Sendable {
    /// The status payload for `maintenanceStatus`.
    public var status: MaintenanceStatus?
    /// The structured failure, present when the request was rejected.
    public var error: RuntimeWireError?

    /// Creates a successful reply.
    public init(status: MaintenanceStatus? = nil) {
        self.status = status
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        status = nil
        self.error = error
    }
}

/// Events published on the `maintenance` topic (runtime-maintenance.md §8.3).
public enum MaintenanceEvent: Codable, Equatable, Sendable {
    /// The host lifecycle state changed.
    case hostStateChanged(HostState)
    /// The self-update probe's snapshot changed.
    case selfUpdateStatusChanged(SelfUpdateStatus)
    /// The Android image update phase changed (runtime-maintenance.md §4.3).
    case imageUpdateChanged(WireImageUpdatePhase)
    /// An event kind added by a newer build.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
    }

    /// Decodes a known maintenance event, preserving a future event as ``unknown``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected one maintenance event case.")
            )
        }
        switch key.stringValue {
        case "hostStateChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .hostStateChanged(try payload.decode(HostState.self, forKey: .first))
        case "selfUpdateStatusChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .selfUpdateStatusChanged(try payload.decode(SelfUpdateStatus.self, forKey: .first))
        case "imageUpdateChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .imageUpdateChanged(try payload.decode(WireImageUpdatePhase.self, forKey: .first))
        case "unknown":
            self = .unknown
        default:
            self = .unknown
        }
    }

    /// Encodes a known maintenance event.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .hostStateChanged(let state):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("hostStateChanged"))
            try payload.encode(state, forKey: .first)
        case .selfUpdateStatusChanged(let status):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("selfUpdateStatusChanged"))
            try payload.encode(status, forKey: .first)
        case .imageUpdateChanged(let phase):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("imageUpdateChanged"))
            try payload.encode(phase, forKey: .first)
        case .unknown:
            Self.encodeEmpty("unknown", into: &container)
        }
    }

    private static func encodeEmpty(
        _ caseName: String,
        into container: inout KeyedEncodingContainer<RuntimeEventCodingKey>
    ) {
        _ = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey(caseName))
    }
}

// MARK: - Android image update

/// One image version the updater might apply (runtime-maintenance.md §4.3).
public struct WireImageCandidate: Codable, Equatable, Sendable {
    /// The image version.
    public var version: String
    /// The feed channel the entry came from, if any.
    public var channel: String?
    /// Expected SHA-256 of the archive, lower-case hex, when the feed gave one.
    public var archiveSHA256: String?
    /// Expected archive size in bytes, when the feed gave one.
    public var archiveSize: Int64?
    /// The installed tree's size, for the space check.
    public var expandedSize: Int64?
    /// Where the archive comes from.
    public var archiveLocation: String?
    /// Whether the entry is critical (ignores the rollout bucket).
    public var isCritical: Bool

    /// Creates a candidate.
    public init(
        version: String,
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

/// The image-update phase machine (runtime-maintenance.md §4.3), wire form.
public enum WireImageUpdatePhase: Equatable, Sendable {
    /// Up to date, or nothing compatible.
    case idle
    /// A check is running.
    case checking
    /// A compatible candidate exists but no download started.
    case available(WireImageCandidate)
    /// A download is running.
    case downloading(WireImageCandidate, progress: Double)
    /// An archive is being extracted and verified.
    case installing(WireImageCandidate, fraction: Double)
    /// In `Images/`, not current; waiting for the apply gate.
    case ready(String)
    /// The migration is running.
    case applying(from: String, to: String)
    /// A check, download, install, or apply failed.
    case failed(WireImageCandidate?, reason: String, retryAt: Date?)
}

/// A rejected image version (runtime-maintenance.md §4.8).
public struct WireRejectedImage: Codable, Equatable, Sendable {
    /// The rejected version.
    public var version: String
    /// When the rejection was recorded.
    public var at: Date
    /// `migrationFailed` or `userRolledBack`.
    public var reason: String
    /// The failure detail for `migrationFailed`.
    public var detail: String?

    /// Creates a rejection record.
    public init(version: String, at: Date, reason: String, detail: String? = nil) {
        self.version = version
        self.at = at
        self.reason = reason
        self.detail = detail
    }
}

/// One instance recovery point (`/Recovery/…`, runtime-maintenance.md §4.4).
public struct WireRecoveryPoint: Codable, Equatable, Sendable {
    /// Its directory name (the recovery-point ID for `apkrun image recovery-points delete`).
    public var name: String
    /// The image version it holds, nil for a failed-migration dump.
    public var imageVersion: String?
    /// When it was created.
    public var createdAt: Date
    /// Whether it is a post-mortem dump kept for diagnostics.
    public var isFailedDump: Bool

    /// Creates a recovery-point record.
    public init(name: String, imageVersion: String?, createdAt: Date, isFailedDump: Bool) {
        self.name = name
        self.imageVersion = imageVersion
        self.createdAt = createdAt
        self.isFailedDump = isFailedDump
    }
}

/// The `imageStatus` reply: the update phase plus the installed image facts
/// `apkrun image` and Settings → Storage need (runtime-maintenance.md §4.10).
public struct WireImageStatus: Codable, Equatable, Sendable {
    /// The update phase.
    public var phase: WireImageUpdatePhase
    /// The image Android currently runs.
    public var current: String?
    /// The image Android ran before `current`, kept for rollback (§4.8).
    public var previous: String?
    /// Rejected versions, kept seven days (§4.8).
    public var rejected: [WireRejectedImage]
    /// `installed(<version>)` or `rejected(<version>, <reason>)` — the last apply's outcome.
    public var lastResult: String?
    /// When the last feed check finished (#88).
    public var lastCheckAt: Date?
    /// When the next automatic check is due (#88).
    public var nextCheckAt: Date?
    /// The recovery points of the instance directory (§4.4).
    public var recoveryPoints: [WireRecoveryPoint]

    /// Creates a status snapshot.
    public init(
        phase: WireImageUpdatePhase,
        current: String?,
        previous: String?,
        rejected: [WireRejectedImage],
        lastResult: String?,
        lastCheckAt: Date?,
        nextCheckAt: Date?,
        recoveryPoints: [WireRecoveryPoint]
    ) {
        self.phase = phase
        self.current = current
        self.previous = previous
        self.rejected = rejected
        self.lastResult = lastResult
        self.lastCheckAt = lastCheckAt
        self.nextCheckAt = nextCheckAt
        self.recoveryPoints = recoveryPoints
    }
}

extension WireImageUpdatePhase: Codable {
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
            self = .available(try container.decode(WireImageCandidate.self, forKey: .candidate))
        case .downloading:
            self = .downloading(
                try container.decode(WireImageCandidate.self, forKey: .candidate),
                progress: try container.decode(Double.self, forKey: .progress)
            )
        case .installing:
            self = .installing(
                try container.decode(WireImageCandidate.self, forKey: .candidate),
                fraction: try container.decode(Double.self, forKey: .progress)
            )
        case .ready:
            self = .ready(try container.decode(String.self, forKey: .version))
        case .applying:
            self = .applying(
                from: try container.decode(String.self, forKey: .from),
                to: try container.decode(String.self, forKey: .to)
            )
        case .failed:
            self = .failed(
                try container.decodeIfPresent(WireImageCandidate.self, forKey: .candidate),
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
            try container.encode(to, forKey: .to)
        case .failed(let candidate, let reason, let retryAt):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encodeIfPresent(candidate, forKey: .candidate)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(retryAt, forKey: .retryAt)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, candidate, progress, version, from, to, reason, retryAt
    }
}

/// `installImage` request: the `.aar` arrives as the single FileHandle beside
/// the message (runtime-maintenance.md §4.7).
public struct WireImageInstallRequest: Codable, Sendable {
    /// Call metadata and API version.
    public var header: APIRequestHeader
    /// `true` when the caller already confirmed ("Install anyway?").
    public var assumeYes: Bool

    /// Creates the request.
    public init(header: APIRequestHeader, assumeYes: Bool) {
        self.header = header
        self.assumeYes = assumeYes
    }
}

/// `installImage` reply: `version` is the installed candidate's version.
public struct WireImageInstallReply: Codable, Sendable {
    /// The installed image version, on success.
    public var version: String?
    /// The failure, if any.
    public var error: RuntimeWireError?

    /// Creates the reply.
    public init(version: String? = nil, error: RuntimeWireError? = nil) {
        self.version = version
        self.error = error
    }
}

/// `applyImage` request: the `ready` version to apply.
public struct WireImageApplyRequest: Codable, Sendable {
    /// Call metadata and API version.
    public var header: APIRequestHeader
    /// The version text of the `ready` candidate to apply.
    public var version: String

    /// Creates the request.
    public init(header: APIRequestHeader, version: String) {
        self.header = header
        self.version = version
    }
}

/// `rollbackImage` request: back to `previous`.
public struct WireImageRollbackRequest: Codable, Sendable {
    /// Call metadata and API version.
    public var header: APIRequestHeader

    /// Creates the request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// `deleteImageRecoveryPoint` request.
public struct WireImageRecoveryPointDeleteRequest: Codable, Sendable {
    /// Call metadata and API version.
    public var header: APIRequestHeader
    /// The recovery point name to delete.
    public var name: String

    /// Creates the request.
    public init(header: APIRequestHeader, name: String) {
        self.header = header
        self.name = name
    }
}

/// Shared reply for `applyImage`, `rollbackImage`, and
/// `deleteImageRecoveryPoint`: `result` is a human one-liner for the CLI.
public struct WireImageApplyReply: Codable, Sendable {
    /// A human-readable one-liner for the CLI, on success.
    public var result: String?
    /// The failure, if any.
    public var error: RuntimeWireError?

    /// Creates the reply.
    public init(result: String? = nil, error: RuntimeWireError? = nil) {
        self.result = result
        self.error = error
    }
}

/// `imageStatus` request; the request body only carries the header.
public struct WireImageStatusRequest: Codable, Sendable {
    /// Call metadata and API version.
    public var header: APIRequestHeader

    /// Creates the request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// `imageStatus` reply.
public struct WireImageStatusReply: Codable, Sendable {
    /// The coordinator's status snapshot, on success.
    public var status: WireImageStatus?
    /// The failure, if any.
    public var error: RuntimeWireError?

    /// Creates the reply.
    public init(status: WireImageStatus? = nil, error: RuntimeWireError? = nil) {
        self.status = status
        self.error = error
    }
}
