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
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("updating"))
            try payload.encode(targetBuild, forKey: .first)
        case .restartPending(let bundleBuild):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("restartPending"))
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
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("hostStateChanged"))
            try payload.encode(state, forKey: .first)
        case .selfUpdateStatusChanged(let status):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: RuntimeEventCodingKey("selfUpdateStatusChanged"))
            try payload.encode(status, forKey: .first)
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
