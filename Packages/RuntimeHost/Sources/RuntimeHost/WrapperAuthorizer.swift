import RuntimeAPI

/// A registered wrapper identity bound to one Android package and one code requirement.
public struct WrapperRegistration: Equatable, Sendable {
    /// The wrapper application's bundle identifier.
    public let bundleID: String
    /// The Android package this wrapper may access.
    public let packageID: RuntimePackageID
    /// The code-signing requirement captured when the wrapper was registered.
    public let codeSigningRequirement: String

    /// Creates one trusted wrapper registration.
    public init(bundleID: String, packageID: RuntimePackageID, codeSigningRequirement: String) {
        self.bundleID = bundleID
        self.packageID = packageID
        self.codeSigningRequirement = codeSigningRequirement
    }
}

/// Resolves wrapper bundle claims to server-owned package scope and signing requirements.
///
/// Production callers populate this from the wrapper registry. Tests may inject a single fixture
/// registration without adding a wrapper registry dependency to RuntimeHost.
public struct WrapperAuthorizer: Sendable {
    private let registrations: [String: WrapperRegistration]

    /// Creates an allowlist. The first registration for a bundle identifier wins.
    public init(registrations: [WrapperRegistration] = []) {
        self.registrations = registrations.reduce(into: [:]) { result, registration in
            guard !registration.bundleID.isEmpty,
                !registration.codeSigningRequirement.isEmpty,
                result[registration.bundleID] == nil
            else {
                return
            }
            result[registration.bundleID] = registration
        }
    }

    /// An authorizer with no registered wrappers.
    public static let empty = WrapperAuthorizer()

    func registration(for bundleID: String) -> WrapperRegistration? {
        registrations[bundleID]
    }

    func registration(for request: RuntimeEndpointRequest) -> WrapperRegistration? {
        guard request.kind == .wrapper, request.clientKind == .wrapper else {
            return nil
        }
        return registration(for: request.claimedIdentity)
    }

    func authorizesPackage(_ packageID: RuntimePackageID, for bundleID: String) -> Bool {
        registration(for: bundleID)?.packageID == packageID
    }
}

enum RuntimeWrapperAuthorization {
    static func allowsPackageInfo(
        _ packageID: RuntimePackageID,
        authorizedPackageID: RuntimePackageID?
    ) -> Bool {
        authorizedPackageID == packageID
    }
}
