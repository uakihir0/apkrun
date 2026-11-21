import Foundation

/// The update wire types of runtime-api.md §9.1–§9.3 and
/// update-system.md §2–§5, §10.2.

/// The update authority the user may choose (update-system.md §2.1).
/// `googlePlay` is only set by #98.
public enum AuthorityChoice: String, Codable, Sendable, Equatable, CaseIterable {
    case apkrun
    case manual
    case external
    case googlePlay
}

/// The user-facing update mode (update-system.md §2.2–§2.3). `manual` maps to
/// authority `manual`; `automatic` and `notifyOnly` need authority `apkrun`.
public enum UpdateChoice: String, Codable, Sendable, Equatable, CaseIterable {
    case automatic
    case notifyOnly
    case manual
}

/// A provider spec and its credentials, sent by the client (§9.2).
/// `local` requires `bookmark`; `token` is GitHub-only, stored in the
/// Keychain under `io.apkrun.provider.github`, and never returned.
public struct ProviderSpec: Codable, Sendable, Equatable {
    /// `local:<path>`, `direct:<https-url>`, `fdroid[:<url>#<fingerprint>]`,
    /// or `github:<owner>/<name>[:<glob>][@prerelease]`.
    public var spec: String
    /// A security-scoped bookmark of the local root. Required for `local`.
    public var bookmark: Data?
    /// The GitHub API token. `nil` keeps the stored one; `""` deletes it.
    public var token: String?

    /// Creates a provider spec.
    public init(spec: String, bookmark: Data? = nil, token: String? = nil) {
        self.spec = spec
        self.bookmark = bookmark
        self.token = token
    }
}

/// What `setUpdatePolicy` does with the package's provider (§9.2).
public enum ProviderChange: Codable, Sendable, Equatable {
    /// Keep the stored provider.
    case keep
    /// Replace the stored provider with this spec.
    case set(ProviderSpec)
    /// Remove the stored provider.
    case remove

    private enum CodingKeys: String, CodingKey {
        case kind
        case spec
    }

    private enum Kind: String, Codable {
        case keep
        case set
        case remove
    }

    /// Decodes a provider change kind.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .keep: self = .keep
        case .set: self = .set(try container.decode(ProviderSpec.self, forKey: .spec))
        case .remove: self = .remove
        }
    }

    /// Encodes the provider change as a tagged object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .keep:
            try container.encode(Kind.keep, forKey: .kind)
        case .set(let spec):
            try container.encode(Kind.set, forKey: .kind)
            try container.encode(spec, forKey: .spec)
        case .remove:
            try container.encode(Kind.remove, forKey: .kind)
        }
    }
}

/// The `setUpdatePolicy` payload (§9.2): the mode plus the provider change.
public struct UpdatePolicy: Codable, Sendable, Equatable {
    /// The user's update choice.
    public var choice: UpdateChoice
    /// What happens to the provider; defaults to `keep`.
    public var provider: ProviderChange

    /// Creates an update policy.
    public init(choice: UpdateChoice, provider: ProviderChange = .keep) {
        self.choice = choice
        self.provider = provider
    }
}

/// `setUpdatePolicy` request body (§9.1).
public struct SetUpdatePolicyRequest: Codable, Sendable, Equatable {
    /// The package to change.
    public var packageID: RuntimePackageID
    /// The new policy.
    public var policy: UpdatePolicy

    /// Creates a set-update-policy request.
    public init(packageID: RuntimePackageID, policy: UpdatePolicy) {
        self.packageID = packageID
        self.policy = policy
    }
}

/// `setUpdateAuthority` request body (§9.1).
public struct SetUpdateAuthorityRequest: Codable, Sendable, Equatable {
    /// The package to change.
    public var packageID: RuntimePackageID
    /// The new authority.
    public var authority: AuthorityChoice

    /// Creates a set-update-authority request.
    public init(packageID: RuntimePackageID, authority: AuthorityChoice) {
        self.packageID = packageID
        self.authority = authority
    }
}

/// The provider a `PackageUpdateStatus` reports (§9.2). Never carries a token.
public struct ProviderSummary: Codable, Sendable, Equatable {
    /// `local`, `direct`, `fdroid`, or `github`.
    public var type: String
    /// The folder, host, or `owner/name` the provider serves.
    public var label: String
    /// The GitHub channel, `stable` or `prerelease`; nil elsewhere.
    public var channel: String?
    /// Whether a token is stored for this provider.
    public var hasToken: Bool

    /// Creates a provider summary.
    public init(type: String, label: String, channel: String? = nil, hasToken: Bool = false) {
        self.type = type
        self.label = label
        self.channel = channel
        self.hasToken = hasToken
    }
}

/// A candidate on the wire (§9.2).
public struct WireUpdateCandidate: Codable, Sendable, Equatable {
    /// Android's long version code, when the provider declares one.
    public var versionCode: RuntimeVersionCode?
    /// The display-only Android version name, when present.
    public var versionName: String?
    /// The provider type that offered the candidate.
    public var provider: String
    /// Plain-text release notes, at most 16 KiB.
    public var releaseNotes: String?
    /// When the provider published the release.
    public var publishedAt: Date?
    /// The total download size in bytes, when known.
    public var downloadBytes: Int64?

    /// Creates a wire update candidate.
    public init(
        versionCode: RuntimeVersionCode? = nil,
        versionName: String? = nil,
        provider: String,
        releaseNotes: String? = nil,
        publishedAt: Date? = nil,
        downloadBytes: Int64? = nil
    ) {
        self.versionCode = versionCode
        self.versionName = versionName
        self.provider = provider
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
        self.downloadBytes = downloadBytes
    }
}

/// A gate that keeps an install waiting (update-system.md §7.1).
public enum WaitingReason: String, Codable, Sendable, Equatable {
    /// The runtime is not running (GU1).
    case runtimeNotReady
    /// The app has an open session (GU2).
    case appInUse
    /// The device is busy or unmetered conditions are unmet.
    case conditionsUnmet
    /// A newer staged set replaced this one.
    case superseded
}

/// The terminal outcome of an update run on the wire (§9.2,
/// state-machines.md §6).
public enum WireUpdateOutcome: Codable, Sendable, Equatable {
    /// The new version installed.
    case updated(from: RuntimeVersionCode, to: RuntimeVersionCode)
    /// The update was rolled back.
    case rolledBack(reason: String)
    /// The failed update was kept at the user's choice.
    case keptAfterFailedHealthCheck(reason: String)
    /// The run was skipped.
    case skipped(reason: String, error: WireError?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case from
        case to
        case reason
        case error
    }

    private enum Kind: String, Codable {
        case updated
        case rolledBack
        case keptAfterFailedHealthCheck
        case skipped
    }

    /// Decodes an update outcome kind.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .updated:
            self = .updated(
                from: try container.decode(RuntimeVersionCode.self, forKey: .from),
                to: try container.decode(RuntimeVersionCode.self, forKey: .to))
        case .rolledBack:
            self = .rolledBack(reason: try container.decode(String.self, forKey: .reason))
        case .keptAfterFailedHealthCheck:
            self = .keptAfterFailedHealthCheck(
                reason: try container.decode(String.self, forKey: .reason))
        case .skipped:
            self = .skipped(
                reason: try container.decode(String.self, forKey: .reason),
                error: try container.decodeIfPresent(WireError.self, forKey: .error))
        }
    }

    /// Encodes the update outcome as a tagged object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .updated(let from, let to):
            try container.encode(Kind.updated, forKey: .kind)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        case .rolledBack(let reason):
            try container.encode(Kind.rolledBack, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .keptAfterFailedHealthCheck(let reason):
            try container.encode(Kind.keptAfterFailedHealthCheck, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .skipped(let reason, let error):
            try container.encode(Kind.skipped, forKey: .kind)
            try container.encode(reason, forKey: .reason)
            try container.encodeIfPresent(error, forKey: .error)
        }
    }
}

/// The update phase on the wire (§9.2, state-machines.md §6).
public enum WireUpdatePhase: Codable, Sendable, Equatable {
    case checking
    case available(WireUpdateCandidate)
    case downloading(progress: Double)
    case validating
    case staged
    case installing
    case healthChecking
    case rollingBack(reason: String)
    case completed(WireUpdateOutcome)
    /// A phase a newer peer reported that this build does not know.
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind
        case candidate
        case progress
        case reason
        case outcome
    }

    private enum Kind: String, Codable {
        case checking
        case available
        case downloading
        case validating
        case staged
        case installing
        case healthChecking
        case rollingBack
        case completed
        case unknown
    }

    /// Decodes an update phase kind.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .checking: self = .checking
        case .available:
            self = .available(try container.decode(WireUpdateCandidate.self, forKey: .candidate))
        case .downloading:
            self = .downloading(progress: try container.decode(Double.self, forKey: .progress))
        case .validating: self = .validating
        case .staged: self = .staged
        case .installing: self = .installing
        case .healthChecking: self = .healthChecking
        case .rollingBack:
            self = .rollingBack(reason: try container.decode(String.self, forKey: .reason))
        case .completed:
            self = .completed(try container.decode(WireUpdateOutcome.self, forKey: .outcome))
        case .unknown: self = .unknown
        }
    }

    /// Encodes the update phase as a tagged object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .checking:
            try container.encode(Kind.checking, forKey: .kind)
        case .available(let candidate):
            try container.encode(Kind.available, forKey: .kind)
            try container.encode(candidate, forKey: .candidate)
        case .downloading(let progress):
            try container.encode(Kind.downloading, forKey: .kind)
            try container.encode(progress, forKey: .progress)
        case .validating:
            try container.encode(Kind.validating, forKey: .kind)
        case .staged:
            try container.encode(Kind.staged, forKey: .kind)
        case .installing:
            try container.encode(Kind.installing, forKey: .kind)
        case .healthChecking:
            try container.encode(Kind.healthChecking, forKey: .kind)
        case .rollingBack(let reason):
            try container.encode(Kind.rollingBack, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .completed(let outcome):
            try container.encode(Kind.completed, forKey: .kind)
            try container.encode(outcome, forKey: .outcome)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}

/// Per-package update state for `listUpdates` (§9.2).
public struct PackageUpdateStatus: Codable, Sendable, Equatable {
    /// The package.
    public var packageID: RuntimePackageID
    /// The user's update choice; nil for `googlePlay` and `external`.
    public var choice: UpdateChoice?
    /// The record's update authority.
    public var authority: String
    /// The configured provider, if any.
    public var provider: ProviderSummary?
    /// The current phase, when one runs or persists.
    public var phase: WireUpdatePhase?
    /// The current candidate, when one is available or staged.
    public var candidate: WireUpdateCandidate?
    /// The last completed check.
    public var lastCheckAt: Date?
    /// The next scheduled check.
    public var nextCheckAt: Date?
    /// Consecutive check failures for backoff display.
    public var consecutiveFailures: Int
    /// False gates keeping an install waiting (GU1…GU7).
    public var waiting: [WaitingReason]

    /// Creates a package update status.
    public init(
        packageID: RuntimePackageID,
        choice: UpdateChoice? = nil,
        authority: String,
        provider: ProviderSummary? = nil,
        phase: WireUpdatePhase? = nil,
        candidate: WireUpdateCandidate? = nil,
        lastCheckAt: Date? = nil,
        nextCheckAt: Date? = nil,
        consecutiveFailures: Int = 0,
        waiting: [WaitingReason] = []
    ) {
        self.packageID = packageID
        self.choice = choice
        self.authority = authority
        self.provider = provider
        self.phase = phase
        self.candidate = candidate
        self.lastCheckAt = lastCheckAt
        self.nextCheckAt = nextCheckAt
        self.consecutiveFailures = consecutiveFailures
        self.waiting = waiting
    }
}

/// `checkForUpdates` request body (§9.1). `packages` nil means every
/// `apkrun`-authority package; `checkOnly` reports without acting.
public struct CheckForUpdatesRequest: Codable, Sendable, Equatable {
    /// Packages to check; nil selects every `apkrun` package.
    public var packages: [RuntimePackageID]?
    /// Report only, without downloading or notifying.
    public var checkOnly: Bool

    /// Creates a check-for-updates request.
    public init(packages: [RuntimePackageID]? = nil, checkOnly: Bool = false) {
        self.packages = packages
        self.checkOnly = checkOnly
    }
}

/// One package's result of a `checkForUpdates` run (§9.2).
public struct UpdateCheckResult: Codable, Sendable, Equatable {
    /// The checked package.
    public var packageID: RuntimePackageID

    /// What the check found.
    public enum Result: Codable, Sendable, Equatable {
        /// The provider has nothing newer.
        case upToDate
        /// A newer candidate exists.
        case available(WireUpdateCandidate)
        /// The update installed.
        case installed(from: RuntimeVersionCode, to: RuntimeVersionCode)
        /// The install waits on a gate.
        case waiting(WaitingReason)
        /// The check failed.
        case failed(WireError)

        private enum CodingKeys: String, CodingKey {
            case kind
            case candidate
            case from
            case to
            case reason
            case error
        }

        private enum Kind: String, Codable {
            case upToDate
            case available
            case installed
            case waiting
            case failed
        }

        /// Decodes a per-package check outcome kind.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .upToDate: self = .upToDate
            case .available:
                self = .available(try container.decode(WireUpdateCandidate.self, forKey: .candidate))
            case .installed:
                self = .installed(
                    from: try container.decode(RuntimeVersionCode.self, forKey: .from),
                    to: try container.decode(RuntimeVersionCode.self, forKey: .to))
            case .waiting:
                self = .waiting(try container.decode(WaitingReason.self, forKey: .reason))
            case .failed:
                self = .failed(try container.decode(WireError.self, forKey: .error))
            }
        }

        /// Encodes the check outcome as a tagged object.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .upToDate:
                try container.encode(Kind.upToDate, forKey: .kind)
            case .available(let candidate):
                try container.encode(Kind.available, forKey: .kind)
                try container.encode(candidate, forKey: .candidate)
            case .installed(let from, let to):
                try container.encode(Kind.installed, forKey: .kind)
                try container.encode(from, forKey: .from)
                try container.encode(to, forKey: .to)
            case .waiting(let reason):
                try container.encode(Kind.waiting, forKey: .kind)
                try container.encode(reason, forKey: .reason)
            case .failed(let error):
                try container.encode(Kind.failed, forKey: .kind)
                try container.encode(error, forKey: .error)
            }
        }
    }

    /// The outcome of the package's check.
    public var outcome: Result

    /// Creates an update check result.
    public init(packageID: RuntimePackageID, outcome: Result) {
        self.packageID = packageID
        self.outcome = outcome
    }
}

/// `updateHistory` request body (§9.1). `packageID` nil reads every package;
/// `limit` defaults to 50 and clamps to 1000.
public struct UpdateHistoryRequest: Codable, Sendable, Equatable {
    /// The package to read; nil means every package.
    public var packageID: RuntimePackageID?
    /// The maximum entries, newest first.
    public var limit: Int?

    /// Creates an update-history request.
    public init(packageID: RuntimePackageID? = nil, limit: Int? = nil) {
        self.packageID = packageID
        self.limit = limit
    }
}

/// One `history.jsonl` line on the wire (update-system.md §10.2).
public struct UpdateHistoryEntry: Codable, Sendable, Equatable {
    /// The schema version, always 1.
    public var v: Int
    /// When the run finished.
    public var time: Date
    /// The package.
    public var packageID: RuntimePackageID
    /// The installed versionCode before the run.
    public var from: RuntimeVersionCode?
    /// The target versionCode, when the run had one.
    public var to: RuntimeVersionCode?
    /// The provider type that ran.
    public var provider: String?
    /// What started the run.
    public var trigger: String
    /// The outcome name, such as `available` or `skipped.checkFailed`.
    public var outcome: String
    /// The failure, when the run failed.
    public var failure: WireError?
    /// Per-phase durations in milliseconds.
    public var phaseDurationsMs: [String: Int]

    /// Creates an update history entry.
    public init(
        v: Int = 1,
        time: Date,
        packageID: RuntimePackageID,
        from: RuntimeVersionCode? = nil,
        to: RuntimeVersionCode? = nil,
        provider: String? = nil,
        trigger: String,
        outcome: String,
        failure: WireError? = nil,
        phaseDurationsMs: [String: Int] = [:]
    ) {
        self.v = v
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

/// A `checkForUpdates` control request.
public struct RuntimeCheckForUpdatesControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// Packages to check; nil selects every `apkrun` package.
    public var packages: [RuntimePackageID]?
    /// Report only, without downloading or notifying.
    public var checkOnly: Bool

    /// Creates a control request.
    public init(header: APIRequestHeader, packages: [RuntimePackageID]? = nil, checkOnly: Bool = false) {
        self.header = header
        self.packages = packages
        self.checkOnly = checkOnly
    }
}

/// The `checkForUpdates` reply: the accepted operation plus, for
/// `checkOnly`, the results once checks finish.
public struct RuntimeCheckForUpdatesControlReply: Codable, Sendable {
    /// The long-running check operation.
    public var operation: OperationHandle?
    /// Results per package, populated for `checkOnly` requests.
    public var results: [UpdateCheckResult]?
    /// The failure on error, for example `update.providerNotConfigured`.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(
        operation: OperationHandle? = nil,
        results: [UpdateCheckResult]? = nil,
        error: RuntimeWireError? = nil
    ) {
        self.operation = operation
        self.results = results
        self.error = error
    }
}

/// The `updatePackage` options (runtime-api.md §9.2).
public struct UpdateNowOptions: Codable, Sendable, Equatable {
    /// End the package's open session before installing (`--now`).
    public var closeRunningApp: Bool
    /// Manual update files (`apkrun update --file`); when set, the request
    /// carries file handles like `importPackage` does.
    public var files: [RuntimeImportSourceFile]?

    /// Creates update options.
    public init(closeRunningApp: Bool = false, files: [RuntimeImportSourceFile]? = nil) {
        self.closeRunningApp = closeRunningApp
        self.files = files
    }
}

/// An `updatePackage` control request (runtime-api.md §9.1).
public struct RuntimeUpdatePackageControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// The package to check and update now.
    public var packageID: RuntimePackageID
    /// The run options.
    public var options: UpdateNowOptions

    /// Creates a control request.
    public init(
        header: APIRequestHeader, packageID: RuntimePackageID,
        options: UpdateNowOptions = UpdateNowOptions()
    ) {
        self.header = header
        self.packageID = packageID
        self.options = options
    }
}

/// The `updatePackage` reply: the accepted operation plus the run's outcome.
/// `outcome` is nil while the run still waits (for example the app is in use
/// and the update is staged, update-system.md §7.3).
public struct RuntimeUpdatePackageControlReply: Codable, Sendable {
    /// The long-running update operation.
    public var operation: OperationHandle?
    /// The terminal outcome, nil while the run waits.
    public var outcome: WireUpdateOutcome?
    /// The failure on error, for example `store.signerMismatch`.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(
        operation: OperationHandle? = nil,
        outcome: WireUpdateOutcome? = nil,
        error: RuntimeWireError? = nil
    ) {
        self.operation = operation
        self.outcome = outcome
        self.error = error
    }
}

/// A `listUpdates` control request.
public struct RuntimeListUpdatesControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader

    /// Creates a control request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// The `listUpdates` reply.
public struct RuntimeListUpdatesControlReply: Codable, Sendable {
    /// Per-package update state.
    public var updates: [PackageUpdateStatus]?
    /// The failure on error.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(updates: [PackageUpdateStatus]? = nil, error: RuntimeWireError? = nil) {
        self.updates = updates
        self.error = error
    }
}

/// An `updateHistory` control request.
public struct RuntimeUpdateHistoryControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// The package to read; nil means every package.
    public var packageID: RuntimePackageID?
    /// The maximum entries, newest first; default 50, max 1000.
    public var limit: Int?

    /// Creates a control request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID? = nil, limit: Int? = nil) {
        self.header = header
        self.packageID = packageID
        self.limit = limit
    }
}

/// The `updateHistory` reply.
public struct RuntimeUpdateHistoryControlReply: Codable, Sendable {
    /// The history entries, newest first.
    public var entries: [UpdateHistoryEntry]?
    /// The failure on error, for example `store.packageNotFound`.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(entries: [UpdateHistoryEntry]? = nil, error: RuntimeWireError? = nil) {
        self.entries = entries
        self.error = error
    }
}

/// A `setUpdatePolicy` control request.
public struct RuntimeSetUpdatePolicyControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// The package to change.
    public var packageID: RuntimePackageID
    /// The new policy.
    public var policy: UpdatePolicy

    /// Creates a control request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID, policy: UpdatePolicy) {
        self.header = header
        self.packageID = packageID
        self.policy = policy
    }
}

/// The `setUpdatePolicy` reply: the package's update status after the write.
public struct RuntimeSetUpdatePolicyControlReply: Codable, Sendable {
    /// The updated status on success.
    public var status: PackageUpdateStatus?
    /// The failure on error, for example `update.authorityDoesNotAllowUpdates`.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(status: PackageUpdateStatus? = nil, error: RuntimeWireError? = nil) {
        self.status = status
        self.error = error
    }
}

/// A `setUpdateAuthority` control request.
public struct RuntimeSetUpdateAuthorityControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// The package to change.
    public var packageID: RuntimePackageID
    /// The new authority.
    public var authority: AuthorityChoice

    /// Creates a control request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID, authority: AuthorityChoice) {
        self.header = header
        self.packageID = packageID
        self.authority = authority
    }
}

/// The `setUpdateAuthority` reply: the package's update status after the write.
public struct RuntimeSetUpdateAuthorityControlReply: Codable, Sendable {
    /// The updated status on success.
    public var status: PackageUpdateStatus?
    /// The failure on error, for example `update.authorityDoesNotAllowUpdates`.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(status: PackageUpdateStatus? = nil, error: RuntimeWireError? = nil) {
        self.status = status
        self.error = error
    }
}

/// A `rollbackPackage` control request (update-system.md §8.5).
public struct RuntimeRollbackPackageControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// The package to roll back to `previous/`.
    public var packageID: RuntimePackageID
    /// Permits the §7.3 uninstall + first-install fallback; only the
    /// confirmed "Restore (erases data)" choice sets it.
    public var allowDataLoss: Bool

    /// Creates a control request.
    public init(
        header: APIRequestHeader,
        packageID: RuntimePackageID,
        allowDataLoss: Bool = false
    ) {
        self.header = header
        self.packageID = packageID
        self.allowDataLoss = allowDataLoss
    }
}

/// The `rollbackPackage` reply.
public struct RuntimeRollbackPackageControlReply: Codable, Sendable {
    /// The version rolled back to, on success.
    public var rolledBackTo: RuntimeVersionCode?
    /// True when no `previous/` set or no rollback mechanism exists (§7.3).
    public var unavailable: Bool?
    /// The failure on error.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(
        rolledBackTo: RuntimeVersionCode? = nil,
        unavailable: Bool? = nil,
        error: RuntimeWireError? = nil
    ) {
        self.rolledBackTo = rolledBackTo
        self.unavailable = unavailable
        self.error = error
    }
}

/// An `updateSkipped` control request (update-system.md §8.4): adds or
/// removes a versionCode on the package's skip list.
public struct RuntimeUpdateSkipControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// The package whose skip list changes.
    public var packageID: RuntimePackageID
    /// The versionCode to skip or unskip.
    public var versionCode: RuntimeVersionCode
    /// True adds the version ("Skip This Version"); false removes it
    /// ("Try Again", `apkrun update unskip`).
    public var skipped: Bool

    /// Creates a control request.
    public init(
        header: APIRequestHeader,
        packageID: RuntimePackageID,
        versionCode: RuntimeVersionCode,
        skipped: Bool
    ) {
        self.header = header
        self.packageID = packageID
        self.versionCode = versionCode
        self.skipped = skipped
    }
}

/// The `updateSkipped` reply.
public struct RuntimeUpdateSkipControlReply: Codable, Sendable {
    /// The failure on error.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(error: RuntimeWireError? = nil) {
        self.error = error
    }
}

/// Starts a package repair asynchronously (package-store.md §11.1,
/// runtime-api.md §8.4): a `broken` package is reinstalled from `current/`.
public struct RuntimeBeginRepairPackageControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata. Its operation ID is reused by the returned handle.
    public let header: APIRequestHeader
    /// The package to repair.
    public let request: RuntimePackageRequest

    /// Creates a begin-repair request.
    public init(header: APIRequestHeader, request: RuntimePackageRequest) {
        self.header = header
        self.request = request
    }
}

/// The result or structured failure for a begin-repair request.
public struct RuntimeBeginRepairPackageControlReply: Codable, Equatable, Sendable {
    /// The long-running repair handle, present on success.
    public let result: OperationHandle?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: OperationHandle) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// A `getConfig` control request (configuration.md §2.7). `keys` nil means
/// every known `updates.*` key.
public struct RuntimeConfigGetControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// Keys to read; nil selects every `updates.*` key.
    public var keys: [String]?

    /// Creates a control request.
    public init(header: APIRequestHeader, keys: [String]? = nil) {
        self.header = header
        self.keys = keys
    }
}

/// The `getConfig` reply: the current values.
public struct RuntimeConfigGetControlReply: Codable, Sendable {
    /// The settings values keyed by name.
    public var values: [String: String]?
    /// The failure on error, for example `config.unknownKey`.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(values: [String: String]? = nil, error: RuntimeWireError? = nil) {
        self.values = values
        self.error = error
    }
}

/// A `setConfig` control request (configuration.md §2.7).
public struct RuntimeConfigSetControlRequest: Codable, Sendable {
    /// The common request header.
    public var header: APIRequestHeader
    /// The `updates.*` key to write.
    public var key: String
    /// The new value.
    public var value: String

    /// Creates a control request.
    public init(header: APIRequestHeader, key: String, value: String) {
        self.header = header
        self.key = key
        self.value = value
    }
}

/// The `setConfig` reply: the values after the write.
public struct RuntimeConfigSetControlReply: Codable, Sendable {
    /// The settings values keyed by name.
    public var values: [String: String]?
    /// The failure on error, for example `config.invalidValue`.
    public var error: RuntimeWireError?

    /// Creates a control reply.
    public init(values: [String: String]? = nil, error: RuntimeWireError? = nil) {
        self.values = values
        self.error = error
    }
}
