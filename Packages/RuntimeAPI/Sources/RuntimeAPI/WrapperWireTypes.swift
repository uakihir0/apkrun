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
