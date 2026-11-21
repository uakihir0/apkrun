import Foundation

/// The wire-level wrapper types of runtime-api.md §10. The domain types that
/// cross the endpoint (`WrapperState`, `BundleProblem`, `WrapperSigner`,
/// `WrapperKindTag`) live here so both WrapperCore and wire clients use the
/// same serialization.
///
/// The computed state of a wrapper (wrapper.md §9.1). Never stored.
public enum WrapperState: Codable, Sendable, Equatable {
    /// The bundle passed every check.
    case valid
    /// Found at a new location; the registry was updated.
    case moved(URL)
    /// No bundle at the bookmark or path, or it is in the Trash.
    case missing
    /// macOS privacy controls deny access to the location.
    case inaccessible
    /// The bundle was modified after signing, or its cdhash differs.
    case signatureInvalid
    /// The registry's package has no record in the store any more.
    case unknownPackage
}

/// The reason a wrapper needs regeneration (wrapper.md §9.1 step 6).
public enum WrapperRefreshReason: Codable, Sendable, Hashable {
    /// `APKRunLauncherVersion` is below the current template's version.
    case launcher(version: String)
    /// The bundled icon differs from the current Android icon.
    case icon
    /// The display name changed.
    case displayName
}

/// The static-check failures of wrapper.md §13 (`BundleProblem`).
public enum BundleProblem: String, Sendable, Codable, Equatable {
    /// The signature fails verification.
    case signatureInvalid
    /// The signer does not match the registered signer.
    case identifierMismatch
    /// `CFBundleIdentifier` does not equal `map(APKRunPackageID)`.
    case bundleIDMismatch
    /// `wrapper.json` is missing, oversized, or schema-invalid.
    case wrapperJSONInvalid
    /// `wrapper.json` names a different package than `APKRunPackageID`.
    case packageMismatch
}

/// Who signed the wrapper executable (runtime-api.md §10.4).
public enum WrapperSigner: Codable, Sendable, Equatable {
    /// An ad-hoc signature.
    case adHoc
    /// A Developer ID signature.
    case developerID(teamID: String?, teamName: String?, notarized: Bool)
    /// The signer could not be determined.
    case unknown
}

/// The wrapper kind on the wire (runtime-api.md §10.4).
public enum WrapperKindTag: String, Codable, Sendable {
    /// A normal `~/Applications` wrapper.
    case local
    /// A self-contained portable wrapper (#89).
    case portable
    /// A distributable wrapper (#90).
    case distribution
}

/// The `verifyWrapper` request (runtime-api.md §10.4).
public struct VerifyWrapperRequest: Codable, Equatable, Sendable {
    /// The bundle to check.
    public let bundleURL: URL
    /// Adds the strict all-architecture signature check (§9.1 check 4).
    public let deep: Bool

    /// Creates a verify request.
    public init(bundleURL: URL, deep: Bool = false) {
        self.bundleURL = bundleURL
        self.deep = deep
    }
}

/// One file of a wrapper bundle's hash list (wrapper.md §9.1).
public struct WrapperFileHashWire: Codable, Equatable, Sendable {
    /// The path relative to the bundle root.
    public let path: String
    /// The lowercase hex SHA-256 of the file's contents.
    public let sha256: String

    /// Creates a file hash entry.
    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

/// The `verifyWrapper` reply (runtime-api.md §10.4).
public struct WrapperVerification: Codable, Equatable, Sendable {
    /// The bundle that was checked.
    public let bundleURL: URL
    /// `CFBundleIdentifier` when the bundle is an APKRun wrapper.
    public let bundleID: String?
    /// `APKRunPackageID` when readable.
    public let packageID: String?
    /// The wrapper kind when readable.
    public let kind: WrapperKindTag?
    /// Whether the bundle ID has a registry entry.
    public let registered: Bool
    /// The registry-observed state; `nil` for bundles that are not wrappers.
    public let state: WrapperState?
    /// The static-check failures found (wrapper.md §13).
    public let problems: [BundleProblem]
    /// The signer when determinable.
    public let signer: WrapperSigner?
    /// The 40-hex code directory hash.
    public let cdhash: String?
    /// `APKRunLauncherVersion`.
    public let launcherVersion: String?
    /// `APKRunLauncherAPI`.
    public let launcherAPI: APIVersion?
    /// The Android version inside a portable wrapper; `nil` otherwise.
    public let bundledVersion: String?
    /// The sorted per-file SHA-256 list of the bundle (wrapper.md §9.1);
    /// present only for a `deep` request.
    public let fileHashes: [WrapperFileHashWire]?

    /// Creates a verification result.
    public init(
        bundleURL: URL,
        bundleID: String? = nil,
        packageID: String? = nil,
        kind: WrapperKindTag? = nil,
        registered: Bool = false,
        state: WrapperState? = nil,
        problems: [BundleProblem] = [],
        signer: WrapperSigner? = nil,
        cdhash: String? = nil,
        launcherVersion: String? = nil,
        launcherAPI: APIVersion? = nil,
        bundledVersion: String? = nil,
        fileHashes: [WrapperFileHashWire]? = nil
    ) {
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.packageID = packageID
        self.kind = kind
        self.registered = registered
        self.state = state
        self.problems = problems
        self.signer = signer
        self.cdhash = cdhash
        self.launcherVersion = launcherVersion
        self.launcherAPI = launcherAPI
        self.bundledVersion = bundledVersion
        self.fileHashes = fileHashes
    }
}

/// Verifies a wrapper bundle through the authenticated control endpoint.
public struct RuntimeVerifyWrapperControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The bundle to check.
    public let bundleURL: URL
    /// Adds the strict all-architecture signature check.
    public let deep: Bool

    /// Creates a verify-wrapper control request.
    public init(header: APIRequestHeader, bundleURL: URL, deep: Bool) {
        self.header = header
        self.bundleURL = bundleURL
        self.deep = deep
    }
}

/// The result or typed error returned by a control verify-wrapper request.
public struct RuntimeVerifyWrapperControlReply: Codable, Equatable, Sendable {
    /// The verification result, present on success.
    public let result: WrapperVerification?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: WrapperVerification) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

// MARK: - placeStagedWrapper (wrapper.md §6.3)

/// Finishes a generation whose destination the daemon cannot reach: the
/// client moved the staged bundle and reports where it went.
public struct RuntimePlaceStagedWrapperControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The token from the `wrapper.destinationNotAccessible` error.
    public let stagingToken: String
    /// Where the client placed the bundle.
    public let finalURL: URL
    /// The client's security bookmark for `finalURL`, base64.
    public let bookmark: String?

    /// Creates a place-staged-wrapper control request.
    public init(header: APIRequestHeader, stagingToken: String, finalURL: URL, bookmark: String?) {
        self.header = header
        self.stagingToken = stagingToken
        self.finalURL = finalURL
        self.bookmark = bookmark
    }
}

/// The result or typed error returned by a control place-staged-wrapper request.
public struct RuntimePlaceStagedWrapperControlReply: Codable, Equatable, Sendable {
    /// The registered wrapper, present on success.
    public let result: WrapperInfo?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: WrapperInfo) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

// MARK: - wrapperInfo (runtime-api.md §10.2)

/// Asks the daemon for the registry row of one package's wrapper.
public struct RuntimeWrapperInfoControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The installed package whose wrapper to describe.
    public let packageID: RuntimePackageID

    /// Creates a wrapper-info control request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID) {
        self.header = header
        self.packageID = packageID
    }
}

/// The result or typed error returned by a control wrapper-info request.
public struct RuntimeWrapperInfoControlReply: Codable, Equatable, Sendable {
    /// The wrapper record, present on success.
    public let result: WrapperInfo?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: WrapperInfo) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

// MARK: - createWrapper (runtime-api.md §10.3)

/// The on-demand status of a wrapper (wrapper.md §9.1). Never stored.
public struct WrapperStatus: Codable, Sendable, Equatable {
    /// The state decided by the first failing check.
    public var state: WrapperState
    /// Why the wrapper wants a refresh.
    public var refreshReasons: Set<WrapperRefreshReason>

    /// Creates a status.
    public init(state: WrapperState, refreshReasons: Set<WrapperRefreshReason> = []) {
        self.state = state
        self.refreshReasons = refreshReasons
    }
}

/// How a wrapper entered the registry (wrapper.md §7.2).
public enum WrapperApproval: String, Codable, Sendable, Equatable {
    /// Generated by this Mac; no prompt needed.
    case generated
    /// Approved by the user.
    case user
}

/// The customization a wrapper carries (runtime-api.md §10.4 `customization`).
public struct WrapperCustomizationWire: Codable, Equatable, Sendable {
    /// The user-chosen display name, when it differs from the package label.
    public var displayName: String?
    /// Whether the icon is a custom file rather than the Android icon.
    public var customIcon: Bool

    /// Creates a customization record.
    public init(displayName: String? = nil, customIcon: Bool = false) {
        self.displayName = displayName
        self.customIcon = customIcon
    }
}

/// One registry row on the wire (runtime-api.md §10.4 `WrapperSummary`).
public struct WrapperSummary: Codable, Equatable, Sendable {
    /// The Android package the wrapper opens.
    public var packageID: RuntimePackageID
    /// `io.apkrun.android.<mapped>`.
    public var bundleID: String
    /// `CFBundleDisplayName`.
    public var displayName: String
    /// The wrapper kind.
    public var kind: WrapperKindTag
    /// The registered bundle location.
    public var bundleURL: URL
    /// The on-demand status.
    public var status: WrapperStatus
    /// How the wrapper entered the registry.
    public var approval: WrapperApproval
    /// `APKRunLauncherVersion`.
    public var launcherVersion: String
    /// When the wrapper was created.
    public var createdAt: Date
    /// The last finished refresh; `nil` before the first.
    public var refreshedAt: Date?

    /// Creates a wrapper summary.
    public init(
        packageID: RuntimePackageID,
        bundleID: String,
        displayName: String,
        kind: WrapperKindTag,
        bundleURL: URL,
        status: WrapperStatus,
        approval: WrapperApproval,
        launcherVersion: String,
        createdAt: Date,
        refreshedAt: Date? = nil
    ) {
        self.packageID = packageID
        self.bundleID = bundleID
        self.displayName = displayName
        self.kind = kind
        self.bundleURL = bundleURL
        self.status = status
        self.approval = approval
        self.launcherVersion = launcherVersion
        self.createdAt = createdAt
        self.refreshedAt = refreshedAt
    }
}

/// The result of `createWrapper` (runtime-api.md §10.4 `WrapperInfo`).
public struct WrapperInfo: Codable, Equatable, Sendable {
    /// The registry row.
    public var summary: WrapperSummary
    /// The bundle file name without `.app`.
    public var fileName: String
    /// The customization the wrapper carries.
    public var customization: WrapperCustomizationWire
    /// Who signed the executable.
    public var signer: WrapperSigner
    /// The 40-hex code directory hash.
    public var cdhash: String
    /// `APKRunLauncherAPI`.
    public var launcherAPI: APIVersion
    /// The `wrapper.json` format version.
    public var formatVersion: Int
    /// The digest of the icon input, when one was used.
    public var iconDigest: RuntimeSHA256Digest?
    /// The last full validation.
    public var lastValidatedAt: Date?
    /// Non-fatal results such as `registrationFailed`.
    public var warnings: [RuntimeWireError]

    /// Creates wrapper info.
    public init(
        summary: WrapperSummary,
        fileName: String,
        customization: WrapperCustomizationWire,
        signer: WrapperSigner,
        cdhash: String,
        launcherAPI: APIVersion,
        formatVersion: Int,
        iconDigest: RuntimeSHA256Digest? = nil,
        lastValidatedAt: Date? = nil,
        warnings: [RuntimeWireError] = []
    ) {
        self.summary = summary
        self.fileName = fileName
        self.customization = customization
        self.signer = signer
        self.cdhash = cdhash
        self.launcherAPI = launcherAPI
        self.formatVersion = formatVersion
        self.iconDigest = iconDigest
        self.lastValidatedAt = lastValidatedAt
        self.warnings = warnings
    }
}

/// Where a generated wrapper goes (runtime-api.md §10.3).
public enum WireWrapperDestination: Codable, Equatable, Sendable {
    /// `~/Applications`.
    case userApplications
    /// `/Applications` (admin only).
    case applications
    /// An explicit directory.
    case directory(URL)
}

/// The icon source for generation (runtime-api.md §10.3).
public enum WrapperIconChoice: Codable, Equatable, Sendable {
    /// The Android icon.
    case android
    /// A user-chosen file sent next to the request (PNG, square, ≥ 512 px).
    case custom(fileIndex: Int)
}

/// The conflict policy of `createWrapper` (runtime-api.md §10.3).
public enum WireReplacePolicy: String, Codable, Sendable {
    /// An existing valid wrapper fails with `wrapper.wrapperExists`.
    case never
    /// Replace only this package's own wrapper.
    case sameWrapper
}

/// Optional `wrapper.json` window defaults (runtime-api.md §10.3).
public struct WrapperWindowDefaultsWire: Codable, Equatable, Sendable {
    /// The default window width in points.
    public var defaultWidth: Int?
    /// The default window height in points.
    public var defaultHeight: Int?
    /// Whether the window can be resized.
    public var resizable: Bool?

    /// Creates window defaults.
    public init(defaultWidth: Int? = nil, defaultHeight: Int? = nil, resizable: Bool? = nil) {
        self.defaultWidth = defaultWidth
        self.defaultHeight = defaultHeight
        self.resizable = resizable
    }
}

/// Optional `wrapper.json` update defaults; valid only with `importTicket`
/// (runtime-api.md §10.3).
public struct WrapperUpdateDefaultsWire: Codable, Equatable, Sendable {
    /// The update authority.
    public var authority: RuntimeUpdateAuthority?
    /// The update mode (`automatic`, `notify`, `manual`).
    public var choice: String?
    /// The provider spec; a token is refused.
    public var provider: String?

    /// Creates update defaults.
    public init(
        authority: RuntimeUpdateAuthority? = nil,
        choice: String? = nil,
        provider: String? = nil
    ) {
        self.authority = authority
        self.choice = choice
        self.provider = provider
    }
}

/// The `createWrapper` request (runtime-api.md §10.3 `WrapperRequest`).
public struct WrapperRequest: Codable, Equatable, Sendable {
    /// The installed package to wrap.
    public var packageID: RuntimePackageID
    /// The destination; `nil` = `wrappers.defaultLocation`.
    public var destination: WireWrapperDestination?
    /// A file name that overrides wrapper.md §4.3 (without `.app`).
    public var fileName: String?
    /// The display name; `nil` = the package's name.
    public var displayName: String?
    /// The icon source; `nil` = the Android icon.
    public var icon: WrapperIconChoice?
    /// A self-contained portable wrapper (#90).
    public var portable: Bool
    /// The conflict policy.
    public var replace: WireReplacePolicy
    /// A portable wrapper of an uninstalled package (#90).
    public var importTicket: RuntimeImportTicket?
    /// `wrapper.json` window defaults.
    public var windowDefaults: WrapperWindowDefaultsWire?
    /// `wrapper.json` update defaults; only with `importTicket`.
    public var updateDefaults: WrapperUpdateDefaultsWire?

    /// Creates a create-wrapper request.
    public init(
        packageID: RuntimePackageID,
        destination: WireWrapperDestination? = nil,
        fileName: String? = nil,
        displayName: String? = nil,
        icon: WrapperIconChoice? = nil,
        portable: Bool = false,
        replace: WireReplacePolicy = .never,
        importTicket: RuntimeImportTicket? = nil,
        windowDefaults: WrapperWindowDefaultsWire? = nil,
        updateDefaults: WrapperUpdateDefaultsWire? = nil
    ) {
        self.packageID = packageID
        self.destination = destination
        self.fileName = fileName
        self.displayName = displayName
        self.icon = icon
        self.portable = portable
        self.replace = replace
        self.importTicket = importTicket
        self.windowDefaults = windowDefaults
        self.updateDefaults = updateDefaults
    }
}

/// Starts a `wrapperCreate` operation on the control endpoint.
public struct RuntimeCreateWrapperControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// What to generate.
    public let request: WrapperRequest

    /// Creates a create-wrapper control request.
    public init(header: APIRequestHeader, request: WrapperRequest) {
        self.header = header
        self.request = request
    }
}

/// The operation handle or typed error returned by `createWrapper`.
public struct RuntimeCreateWrapperControlReply: Codable, Equatable, Sendable {
    /// The operation handle, present on acceptance.
    public let result: OperationHandle?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates an accepted reply.
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

/// A wrapper change published on the `wrappers` event topic
/// (runtime-api.md §10, `WrapperChange`).
public enum WrapperChange: Codable, Equatable, Sendable {
    /// A wrapper was generated or approved.
    case created(WrapperSummary)
    /// A wrapper was regenerated by a refresh.
    case refreshed(WrapperSummary)
    /// A wrapper was removed.
    case removed(RuntimePackageID)
    /// The on-demand status of a wrapper changed (coalesced per package).
    case statusChanged(RuntimePackageID, WrapperStatus)
    /// APKRun.app shows the approval dialog (wrapper.md §7.3 step 4).
    case approvalRequested(ApprovalPrompt)
    /// An approval prompt was answered (wrapper.md §7.3 step 5).
    case approvalResolved(ApprovalID)
    /// The daemon reported a wrapper change added by a newer API version.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
        case status
    }

    /// Decodes a wrapper change or preserves one added by a newer API version.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeEventCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected one wrapper change case."
                )
            )
        }
        switch key.stringValue {
        case "created":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .created(try payload.decode(WrapperSummary.self, forKey: .first))
        case "refreshed":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .refreshed(try payload.decode(WrapperSummary.self, forKey: .first))
        case "removed":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .removed(try payload.decode(RuntimePackageID.self, forKey: .first))
        case "statusChanged":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .statusChanged(
                try payload.decode(RuntimePackageID.self, forKey: .first),
                try payload.decode(WrapperStatus.self, forKey: .status)
            )
        case "approvalRequested":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .approvalRequested(try payload.decode(ApprovalPrompt.self, forKey: .first))
        case "approvalResolved":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .approvalResolved(try payload.decode(ApprovalID.self, forKey: .first))
        default:
            self = .unknown
        }
    }

    /// Encodes a known wrapper change.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeEventCodingKey.self)
        switch self {
        case .created(let summary):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("created")
            )
            try payload.encode(summary, forKey: .first)
        case .refreshed(let summary):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("refreshed")
            )
            try payload.encode(summary, forKey: .first)
        case .removed(let packageID):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("removed")
            )
            try payload.encode(packageID, forKey: .first)
        case .statusChanged(let packageID, let status):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("statusChanged")
            )
            try payload.encode(packageID, forKey: .first)
            try payload.encode(status, forKey: .status)
        case .approvalRequested(let prompt):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("approvalRequested")
            )
            try payload.encode(prompt, forKey: .first)
        case .approvalResolved(let approvalID):
            var payload = container.nestedContainer(
                keyedBy: AssociatedKey.self,
                forKey: RuntimeEventCodingKey("approvalResolved")
            )
            try payload.encode(approvalID, forKey: .first)
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unknown wrapper changes cannot be encoded."
                )
            )
        }
    }
}

// MARK: - Approval (runtime-api.md §10.6, wrapper.md §7.3)

/// The approval kinds that appear in a prompt (runtime-api.md §10.6).
public enum IntegrationKind: String, Codable, Sendable, CaseIterable {
    /// `integrations.clipboard`.
    case clipboard
    /// `integrations.notifications`.
    case notifications
    /// `integrations.links`.
    case links
    /// `integrations.files`.
    case files
    /// `integrations.sharedFolders`.
    case sharedFolders
    /// `integrations.microphone`.
    case microphone
}

/// The value an approval prompt reports for an integration
/// (configuration.md §3.3's cap domain).
public enum WireIntegrationDecision: String, Codable, Sendable, Equatable {
    /// The integration is off.
    case off
    /// The integration is on.
    case on
    /// Shared folders are read-only.
    case readOnly
    /// Shared folders are read-write.
    case readWrite
    /// Links open in Android.
    case android
    /// Links ask where to open.
    case ask
    /// Links open on the Mac.
    case mac
}

/// The identifier of one approval prompt (runtime-api.md §10.6).
public struct ApprovalID: RawRepresentable, Codable, Sendable, Hashable {
    /// The opaque identifier.
    public var rawValue: String

    /// Creates an approval identifier.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// The kind of approval being requested (runtime-api.md §10.6).
public enum ApprovalPromptKind: Codable, Sendable, Equatable {
    /// A wrapper asks to be approved (wrapper.md §7.3).
    case wrapper
    /// A portable bootstrap asks to install a package (runtime-api.md §10.7).
    case bootstrapInstall(RuntimeImportPreview)
}

/// One prompt APKRun.app shows for an approval request (runtime-api.md §10.6).
public struct ApprovalPrompt: Codable, Sendable, Equatable {
    /// The prompt's identifier; `decideApproval` answers with it.
    public var approvalID: ApprovalID
    /// What is being asked.
    public var kind: ApprovalPromptKind
    /// The bundle on disk that is asking.
    public var bundleURL: URL
    /// The bundle's claimed identifier.
    public var bundleID: String
    /// The Android package the wrapper belongs to.
    public var packageID: RuntimePackageID
    /// The wrapper's display name.
    public var displayName: String
    /// Who signed the bundle.
    public var signer: WrapperSigner
    /// Whether the package is installed on this Mac.
    public var packageInstalled: Bool
    /// The installed version, when the package is installed.
    public var installedVersion: String?
    /// The version bundled in a portable wrapper.
    public var bundledVersion: String?
    /// The location of the entry this approval replaces.
    public var replacesURL: URL?
    /// The integrations the app gets, capped by this Mac's defaults.
    public var integrations: [IntegrationKind: WireIntegrationDecision]
    /// A PNG icon of at most 256 px.
    public var icon: Data?
    /// When the request was made.
    public var requestedAt: Date
    /// When the prompt times out (10 minutes).
    public var expiresAt: Date

    /// Creates an approval prompt.
    public init(
        approvalID: ApprovalID,
        kind: ApprovalPromptKind,
        bundleURL: URL,
        bundleID: String,
        packageID: RuntimePackageID,
        displayName: String,
        signer: WrapperSigner,
        packageInstalled: Bool,
        installedVersion: String? = nil,
        bundledVersion: String? = nil,
        replacesURL: URL? = nil,
        integrations: [IntegrationKind: WireIntegrationDecision] = [:],
        icon: Data? = nil,
        requestedAt: Date,
        expiresAt: Date
    ) {
        self.approvalID = approvalID
        self.kind = kind
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.packageID = packageID
        self.displayName = displayName
        self.signer = signer
        self.packageInstalled = packageInstalled
        self.installedVersion = installedVersion
        self.bundledVersion = bundledVersion
        self.replacesURL = replacesURL
        self.integrations = integrations
        self.icon = icon
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

/// The launcher's `requestApproval` broker request (runtime-api.md §3.4).
public struct ApprovalRequest: Codable, Equatable, Sendable {
    /// The bundle on disk that is asking.
    public var bundleURL: URL
    /// The bundle's claimed identifier.
    public var bundleID: String
    /// The Android package the wrapper belongs to.
    public var packageID: RuntimePackageID

    /// Creates an approval request.
    public init(bundleURL: URL, bundleID: String, packageID: RuntimePackageID) {
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.packageID = packageID
    }
}

/// The broker's answer to `requestApproval` (runtime-api.md §3.4).
public enum ApprovalReply: Codable, Equatable, Sendable {
    /// The user allowed the wrapper; repeat `requestEndpoint`.
    case approved
    /// The user denied it until the given date.
    case denied(until: Date)
    /// Nobody answered within 10 minutes.
    case timedOut

    private enum CodingKey: String, Swift.CodingKey {
        case approved
        case denied
        case timedOut
    }

    private enum AssociatedKey: String, Swift.CodingKey {
        case until = "_0"
    }

    /// Decodes an approval reply.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected one approval reply case."
                )
            )
        }
        switch key {
        case .approved:
            self = .approved
        case .denied:
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .denied(until: try payload.decode(Date.self, forKey: .until))
        case .timedOut:
            self = .timedOut
        }
    }

    /// Encodes an approval reply.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKey.self)
        switch self {
        case .approved:
            try container.encode([String: String](), forKey: .approved)
        case .denied(let until):
            var payload = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .denied)
            try payload.encode(until, forKey: .until)
        case .timedOut:
            try container.encode([String: String](), forKey: .timedOut)
        }
    }
}

/// APKRun.app's answer to an approval prompt (runtime-api.md §10.6).
public struct DecideApprovalRequest: Codable, Equatable, Sendable {
    /// The prompt being answered.
    public var approvalID: ApprovalID
    /// Whether the user allowed it.
    public var allow: Bool

    /// Creates a decision.
    public init(approvalID: ApprovalID, allow: Bool) {
        self.approvalID = approvalID
        self.allow = allow
    }
}

/// One denied wrapper in Settings → Privacy (runtime-api.md §10.6).
public struct DeniedWrapper: Codable, Equatable, Sendable {
    /// The denied bundle identifier.
    public var bundleID: String
    /// The Android package, when the bundle declared one.
    public var packageID: RuntimePackageID?
    /// The denied cdhash.
    public var cdhash: String
    /// Until when requests are refused at once.
    public var until: Date

    /// Creates a denied wrapper record.
    public init(bundleID: String, packageID: RuntimePackageID?, cdhash: String, until: Date) {
        self.bundleID = bundleID
        self.packageID = packageID
        self.cdhash = cdhash
        self.until = until
    }
}

/// The `clearWrapperDenial` request (runtime-api.md §10.6).
public struct ClearWrapperDenialRequest: Codable, Equatable, Sendable {
    /// The bundle identifier to clear.
    public var bundleID: String
    /// The denied cdhash to clear.
    public var cdhash: String

    /// Creates a clear request.
    public init(bundleID: String, cdhash: String) {
        self.bundleID = bundleID
        self.cdhash = cdhash
    }
}

// MARK: - Approval control operations (runtime-api.md §10.2)

/// The `pendingApprovals` control request (runtime-api.md §10.6).
public struct RuntimePendingApprovalsControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a pending-approvals request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// The result or typed error returned by `pendingApprovals`.
public struct RuntimePendingApprovalsControlReply: Codable, Equatable, Sendable {
    /// The waiting prompts, present on success.
    public let result: [ApprovalPrompt]?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: [ApprovalPrompt]) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The `decideApproval` control request (runtime-api.md §10.6).
public struct RuntimeDecideApprovalControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The prompt being answered.
    public let approvalID: ApprovalID
    /// Whether the user allowed it.
    public let allow: Bool

    /// Creates a decide-approval request.
    public init(header: APIRequestHeader, approvalID: ApprovalID, allow: Bool) {
        self.header = header
        self.approvalID = approvalID
        self.allow = allow
    }
}

/// The result or typed error returned by `decideApproval`.
public struct RuntimeDecideApprovalControlReply: Codable, Equatable, Sendable {
    /// `true` on success, absent on failure.
    public let acknowledged: Bool?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init() {
        acknowledged = true
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        acknowledged = nil
        self.error = error
    }
}

/// The `deniedWrappers` control request (runtime-api.md §10.6).
public struct RuntimeDeniedWrappersControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a denied-wrappers request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// The result or typed error returned by `deniedWrappers`.
public struct RuntimeDeniedWrappersControlReply: Codable, Equatable, Sendable {
    /// The denied wrappers, present on success.
    public let result: [DeniedWrapper]?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: [DeniedWrapper]) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The `clearWrapperDenial` control request (runtime-api.md §10.6).
public struct RuntimeClearWrapperDenialControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The bundle identifier to clear.
    public let bundleID: String
    /// The denied cdhash to clear.
    public let cdhash: String

    /// Creates a clear-wrapper-denial request.
    public init(header: APIRequestHeader, bundleID: String, cdhash: String) {
        self.header = header
        self.bundleID = bundleID
        self.cdhash = cdhash
    }
}

/// The result or typed error returned by `clearWrapperDenial`.
public struct RuntimeClearWrapperDenialControlReply: Codable, Equatable, Sendable {
    /// `true` on success, absent on failure.
    public let acknowledged: Bool?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init() {
        acknowledged = true
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        acknowledged = nil
        self.error = error
    }
}

/// The reply to the broker's `requestApproval` (runtime-api.md §3.4).
public struct RuntimeApprovalBrokerReply: Codable, Equatable, Sendable {
    /// The approval reply, present on success.
    public let result: ApprovalReply?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: ApprovalReply) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

// MARK: - wrapper lifecycle (runtime-api.md §10.5, wrapper.md §9)

/// One row of `listWrappers`: the registry summary plus the status the
/// validator computed (wrapper.md §9.1). The status is never stored.
public struct WrapperListEntryWire: Codable, Equatable, Sendable {
    /// The registry row.
    public var summary: WrapperSummary
    /// The validator's state, or nil when validation could not run.
    public var state: WrapperState?
    /// Why the wrapper wants a refresh (check 6 of §9.1).
    public var refreshReasons: [WrapperRefreshReason]

    /// Creates a list entry.
    public init(
        summary: WrapperSummary,
        state: WrapperState? = nil,
        refreshReasons: [WrapperRefreshReason] = []
    ) {
        self.summary = summary
        self.state = state
        self.refreshReasons = refreshReasons
    }
}

/// A `listWrappers` control request; has no parameters.
public struct RuntimeWrapperListControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a list-wrappers control request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// The result or typed error returned by a control list-wrappers request.
public struct RuntimeWrapperListControlReply: Codable, Equatable, Sendable {
    /// The wrapper rows, present on success.
    public let result: [WrapperListEntryWire]?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: [WrapperListEntryWire]) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// A `removeWrapper` control request (wrapper.md §9.5): drops the registry
/// entry, and with `trash` moves the bundle to the Trash first.
public struct RuntimeRemoveWrapperControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The installed package whose wrapper to remove.
    public let packageID: RuntimePackageID
    /// Move the bundle to the Trash before dropping the entry.
    public let trash: Bool

    /// Creates a remove-wrapper control request.
    public init(header: APIRequestHeader, packageID: RuntimePackageID, trash: Bool) {
        self.header = header
        self.packageID = packageID
        self.trash = trash
    }
}

/// The result or typed error returned by a control remove-wrapper request.
public struct RuntimeRemoveWrapperControlReply: Codable, Equatable, Sendable {
    /// Whether an entry was removed, present on success.
    public let result: Bool?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: Bool) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// A `rescanWrappers` control request (wrapper.md §7.2): lists, or with
/// `register` also registers, the valid `APKRunPackageID` bundles in
/// `~/Applications` and `/Applications`.
public struct RuntimeRescanWrappersControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// Register the found bundles, not just list them.
    public let register: Bool

    /// Creates a rescan-wrappers control request.
    public init(header: APIRequestHeader, register: Bool) {
        self.header = header
        self.register = register
    }
}

/// The result or typed error returned by a control rescan-wrappers request.
public struct RuntimeRescanWrappersControlReply: Codable, Equatable, Sendable {
    /// The bundle paths found and registered, present on success.
    public let result: RescanWrappersResult?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RescanWrappersResult) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The `rescanWrappers` outcome: the bundle paths the scan found, and the
/// ones `register = true` newly registered.
public struct RescanWrappersResult: Codable, Equatable, Sendable {
    /// Every wrapper bundle found, as a path.
    public var found: [String]
    /// The bundles that were registered by this call.
    public var registered: [String]

    /// Creates a rescan result.
    public init(found: [String], registered: [String]) {
        self.found = found
        self.registered = registered
    }
}

// MARK: - wrapper refresh (runtime-api.md §10.5, wrapper.md §9.3)

/// What a refresh changes (wrapper.md §9.3): name, icon, or launcher.
public struct WrapperRefreshWire: Codable, Equatable, Sendable {
    /// The new display name; `""` resets it to the package name.
    public var displayName: String?
    /// A replacement icon arrives as the call's file handle.
    public var icon: Bool
    /// Only the launcher executable is refreshed.
    public var launcherOnly: Bool
    /// Makes the package local (wrapper.md §10.2) — #90 rejects it for now.
    public var makeLocal: Bool
    /// Answers "Quit ‹App› to update its Mac app?" with yes.
    public var closeRunningApp: Bool

    /// Creates the refresh options.
    public init(
        displayName: String? = nil,
        icon: Bool = false,
        launcherOnly: Bool = false,
        makeLocal: Bool = false,
        closeRunningApp: Bool = false
    ) {
        self.displayName = displayName
        self.icon = icon
        self.launcherOnly = launcherOnly
        self.makeLocal = makeLocal
        self.closeRunningApp = closeRunningApp
    }
}

/// The `refreshWrapper` request (runtime-api.md §10.5).
public struct RuntimeRefreshWrapperControlRequest: Codable, Equatable, Sendable {
    /// The request header.
    public var header: APIRequestHeader
    /// The package whose wrapper refreshes.
    public var packageID: RuntimePackageID
    /// What the refresh changes.
    public var change: WrapperRefreshWire

    /// Creates the request.
    public init(
        header: APIRequestHeader,
        packageID: RuntimePackageID,
        change: WrapperRefreshWire
    ) {
        self.header = header
        self.packageID = packageID
        self.change = change
    }
}

/// The `refreshWrapper` reply: an operation handle or a typed error.
public struct RuntimeRefreshWrapperControlReply: Codable, Equatable, Sendable {
    /// The started operation.
    public var result: OperationHandle?
    /// The rejection.
    public var error: RuntimeWireError?

    /// Creates a success reply.
    public init(result: OperationHandle) {
        self.result = result
        error = nil
    }

    /// Creates a rejection reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The `refreshAllWrappers` selection (runtime-api.md §10.5).
public enum RefreshAllScope: String, Codable, Sendable {
    /// Only wrappers with a refresh reason.
    case needingRefresh
    /// Every registered wrapper.
    case all
}

/// The `refreshAllWrappers` request (runtime-api.md §10.5).
public struct RuntimeRefreshAllWrappersControlRequest: Codable, Equatable, Sendable {
    /// The request header.
    public var header: APIRequestHeader
    /// Which wrappers are selected.
    public var scope: RefreshAllScope
    /// Only refresh launcher executables.
    public var launcherOnly: Bool

    /// Creates the request.
    public init(
        header: APIRequestHeader,
        scope: RefreshAllScope,
        launcherOnly: Bool
    ) {
        self.header = header
        self.scope = scope
        self.launcherOnly = launcherOnly
    }
}

/// The `refreshAllWrappers` reply: an operation handle or a typed error.
public struct RuntimeRefreshAllWrappersControlReply: Codable, Equatable, Sendable {
    /// The started operation.
    public var result: OperationHandle?
    /// The rejection.
    public var error: RuntimeWireError?

    /// Creates a success reply.
    public init(result: OperationHandle) {
        self.result = result
        error = nil
    }

    /// Creates a rejection reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// One refresh failure inside a `refreshAllWrappers` batch.
public struct WrapperBatchFailure: Codable, Equatable, Sendable {
    /// The package whose refresh failed.
    public var packageID: RuntimePackageID
    /// The failure.
    public var error: RuntimeWireError

    /// Creates the failure record.
    public init(packageID: RuntimePackageID, error: RuntimeWireError) {
        self.packageID = packageID
        self.error = error
    }
}

/// The `refreshAllWrappers` outcome (runtime-api.md §10.5).
public struct WrapperBatchResult: Codable, Equatable, Sendable {
    /// The wrappers that refreshed successfully.
    public var refreshed: [RuntimePackageID]
    /// The wrappers skipped because their app is running.
    public var skippedRunning: [RuntimePackageID]
    /// The wrappers whose refresh failed.
    public var failed: [WrapperBatchFailure]

    /// Creates the batch result.
    public init(
        refreshed: [RuntimePackageID],
        skippedRunning: [RuntimePackageID],
        failed: [WrapperBatchFailure]
    ) {
        self.refreshed = refreshed
        self.skippedRunning = skippedRunning
        self.failed = failed
    }
}
