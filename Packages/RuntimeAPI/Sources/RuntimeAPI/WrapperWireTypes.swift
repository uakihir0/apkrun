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
        bundledVersion: String? = nil
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
