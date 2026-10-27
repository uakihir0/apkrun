import Foundation

/// A random identifier for one pending wrapper approval.
public struct ApprovalID: Codable, Equatable, Hashable, Sendable {
    /// The UUID value represented by this identifier.
    public let rawValue: UUID

    /// Creates a fresh approval identifier.
    public init() {
        rawValue = UUID()
    }

    /// Creates an identifier from a UUID value.
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Creates an identifier from a UUID string.
    public init?(wire: String) {
        guard let uuid = UUID(uuidString: wire), uuid.uuidString.lowercased() == wire else {
            return nil
        }
        rawValue = uuid
    }

    /// The canonical lowercase UUID string used on the wire.
    public var wireValue: String {
        rawValue.uuidString.lowercased()
    }

    /// Decodes a canonical lowercase UUID string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let approvalID = Self(wire: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Approval ID must be a canonical lowercase UUID."
            )
        }
        self = approvalID
    }

    /// Encodes the identifier as its canonical lowercase UUID string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// A launcher request for approval of an unregistered or changed wrapper.
///
/// The daemon treats these values as claims and must revalidate the bundle at `bundlePath` before
/// displaying or accepting an approval. The path and bundle identifier are bounded before they
/// cross the XPC boundary.
public struct RuntimeWrapperApprovalBrokerRequest: Codable, Equatable, Sendable {
    /// The absolute path to the app bundle being opened.
    public let bundlePath: String
    /// The bundle identifier claimed by the app bundle.
    public let bundleID: String
    /// The Android package identifier claimed by the wrapper.
    public let packageID: RuntimePackageID

    /// Creates a request when the path and bundle identifier are bounded and well formed.
    public init?(bundlePath: String, bundleID: String, packageID: RuntimePackageID) {
        guard RuntimeWrapperApprovalValidation.isAbsolutePath(bundlePath),
            RuntimeWrapperApprovalValidation.isBundleID(bundleID)
        else {
            return nil
        }
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.packageID = packageID
    }

    /// Decodes and validates a broker request.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundlePath = try container.decode(String.self, forKey: .bundlePath)
        let bundleID = try container.decode(String.self, forKey: .bundleID)
        let packageID = try container.decode(RuntimePackageID.self, forKey: .packageID)
        guard let request = Self(bundlePath: bundlePath, bundleID: bundleID, packageID: packageID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundlePath,
                in: container,
                debugDescription: "Invalid wrapper approval request."
            )
        }
        self = request
    }
}

/// The signing facts for a wrapper shown in an approval prompt.
public struct RuntimeWrapperSignerSummary: Codable, Equatable, Sendable {
    /// The signature type.
    public enum Kind: Codable, Equatable, Sendable {
        /// The wrapper uses an ad-hoc signature.
        case adHoc
        /// The wrapper has a verified Developer ID signature.
        case developerID
        /// The wrapper is signed by a team, but the certificate class is not established.
        case teamSigned
        /// A signer kind introduced by a newer RuntimeAPI minor version.
        case unknown(String)

        /// Decodes known signer kinds and preserves a future wire value.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            switch value {
            case "adHoc":
                self = .adHoc
            case "developerID":
                self = .developerID
            case "teamSigned":
                self = .teamSigned
            default:
                self = .unknown(value)
            }
        }

        /// Encodes the stable wire value for this signer kind.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .adHoc:
                try container.encode("adHoc")
            case .developerID:
                try container.encode("developerID")
            case .teamSigned:
                try container.encode("teamSigned")
            case .unknown(let value):
                try container.encode(value)
            }
        }
    }

    /// The signature type.
    public let kind: Kind
    /// The signing team identifier, when the signature is team-signed.
    public let teamIdentifier: String?
    /// Whether a Developer ID wrapper is notarized, or `nil` when the host has not assessed it.
    public let notarized: Bool?

    /// Creates a signer summary when its fields are consistent.
    public init?(kind: Kind, teamIdentifier: String? = nil, notarized: Bool? = nil) {
        switch kind {
        case .adHoc:
            guard teamIdentifier == nil, notarized == nil else {
                return nil
            }
        case .developerID:
            guard let teamIdentifier,
                RuntimeWrapperApprovalValidation.isTeamIdentifier(teamIdentifier),
                notarized != nil
            else {
                return nil
            }
        case .teamSigned:
            guard let teamIdentifier,
                RuntimeWrapperApprovalValidation.isTeamIdentifier(teamIdentifier),
                notarized == nil
            else {
                return nil
            }
        case .unknown:
            guard teamIdentifier.map({ RuntimeWrapperApprovalValidation.isTeamIdentifier($0) }) ?? true else {
                return nil
            }
        }
        self.kind = kind
        self.teamIdentifier = teamIdentifier
        self.notarized = notarized
    }

    /// Decodes and validates a signer summary.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let teamIdentifier = try container.decodeIfPresent(String.self, forKey: .teamIdentifier)
        let notarized = try container.decodeIfPresent(Bool.self, forKey: .notarized)
        guard let signer = Self(kind: kind, teamIdentifier: teamIdentifier, notarized: notarized) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Inconsistent wrapper signer summary."
            )
        }
        self = signer
    }
}

/// Effective integration permissions to describe in a wrapper approval prompt.
public struct RuntimeWrapperIntegrationSummary: Codable, Equatable, Sendable {
    /// Whether the wrapper's package can access the clipboard integration.
    public let clipboard: Bool
    /// Whether the wrapper's package can post notifications.
    public let notifications: Bool
    /// Whether the wrapper's package can open links.
    public let links: Bool
    /// Whether the wrapper's package can use file transfer.
    public let files: Bool
    /// Whether the wrapper's package can use shared folders.
    public let sharedFolders: Bool
    /// Whether the wrapper's package can use microphone capture.
    public let microphone: Bool

    /// Creates an integration summary.
    public init(
        clipboard: Bool,
        notifications: Bool,
        links: Bool,
        files: Bool,
        sharedFolders: Bool,
        microphone: Bool
    ) {
        self.clipboard = clipboard
        self.notifications = notifications
        self.links = links
        self.files = files
        self.sharedFolders = sharedFolders
        self.microphone = microphone
    }
}

/// The validated facts displayed by APKRun before a wrapper is approved.
public struct RuntimeWrapperApprovalPrompt: Codable, Equatable, Sendable {
    /// The opaque request identifier used to submit a decision.
    public let approvalID: ApprovalID
    /// The absolute path to the app bundle.
    public let bundlePath: String
    /// The validated bundle identifier.
    public let bundleID: String
    /// The validated Android package identifier.
    public let packageID: RuntimePackageID
    /// The sanitized display name.
    public let displayName: String
    /// The validated code-signing summary.
    public let signer: RuntimeWrapperSignerSummary
    /// Whether the Android package is already installed.
    public let packageInstalled: Bool
    /// The installed Android version, when package metadata is available.
    public let installedVersion: String?
    /// The bundled app version, when the wrapper embeds one.
    public let bundledVersion: String?
    /// The effective integrations permitted by this Mac's settings.
    public let integrations: RuntimeWrapperIntegrationSummary
    /// The active wrapper path that this approval would replace, when present.
    public let replacingBundlePath: String?

    /// Creates a prompt when its display values are bounded.
    public init?(
        approvalID: ApprovalID,
        bundlePath: String,
        bundleID: String,
        packageID: RuntimePackageID,
        displayName: String,
        signer: RuntimeWrapperSignerSummary,
        packageInstalled: Bool,
        installedVersion: String? = nil,
        bundledVersion: String? = nil,
        integrations: RuntimeWrapperIntegrationSummary,
        replacingBundlePath: String? = nil
    ) {
        guard RuntimeWrapperApprovalValidation.isAbsolutePath(bundlePath),
            RuntimeWrapperApprovalValidation.isBundleID(bundleID),
            RuntimeWrapperApprovalValidation.isDisplayName(displayName),
            RuntimeWrapperApprovalValidation.isOptionalVersion(installedVersion),
            RuntimeWrapperApprovalValidation.isOptionalVersion(bundledVersion),
            RuntimeWrapperApprovalValidation.isOptionalAbsolutePath(replacingBundlePath)
        else {
            return nil
        }
        self.approvalID = approvalID
        self.bundlePath = bundlePath
        self.bundleID = bundleID
        self.packageID = packageID
        self.displayName = displayName
        self.signer = signer
        self.packageInstalled = packageInstalled
        self.installedVersion = installedVersion
        self.bundledVersion = bundledVersion
        self.integrations = integrations
        self.replacingBundlePath = replacingBundlePath
    }

    /// Decodes and validates prompt facts before they are shown to the user.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundlePath = try container.decode(String.self, forKey: .bundlePath)
        let bundleID = try container.decode(String.self, forKey: .bundleID)
        let packageID = try container.decode(RuntimePackageID.self, forKey: .packageID)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let signer = try container.decode(RuntimeWrapperSignerSummary.self, forKey: .signer)
        let packageInstalled = try container.decode(Bool.self, forKey: .packageInstalled)
        let installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion)
        let bundledVersion = try container.decodeIfPresent(String.self, forKey: .bundledVersion)
        let integrations = try container.decode(RuntimeWrapperIntegrationSummary.self, forKey: .integrations)
        let replacingBundlePath = try container.decodeIfPresent(String.self, forKey: .replacingBundlePath)
        guard
            let prompt = Self(
                approvalID: try container.decode(ApprovalID.self, forKey: .approvalID),
                bundlePath: bundlePath,
                bundleID: bundleID,
                packageID: packageID,
                displayName: displayName,
                signer: signer,
                packageInstalled: packageInstalled,
                installedVersion: installedVersion,
                bundledVersion: bundledVersion,
                integrations: integrations,
                replacingBundlePath: replacingBundlePath
            )
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundlePath,
                in: container,
                debugDescription: "Invalid wrapper approval prompt."
            )
        }
        self = prompt
    }
}

/// The terminal result of one wrapper approval request.
public enum RuntimeWrapperApprovalOutcome: String, Codable, Equatable, Sendable {
    /// The wrapper was registered.
    case approved
    /// The user denied the wrapper.
    case denied
    /// No user decision arrived before the request expired.
    case timedOut
    /// The daemon returned an outcome added by a newer API version.
    case unknown

    /// Decodes an outcome, preserving values added by newer API versions.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    /// Encodes a stable approval outcome.
    public func encode(to encoder: any Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown approval outcomes cannot be encoded.")
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The broker's response after an approval request resolves.
public struct RuntimeWrapperApprovalBrokerReply: Codable, Equatable, Sendable {
    /// The terminal approval result, present when the request resolved.
    public let result: RuntimeWrapperApprovalOutcome?
    /// A typed rejection, present when the broker could not accept the request.
    public let error: RuntimeWireError?

    /// Creates a successful broker reply.
    public init(result: RuntimeWrapperApprovalOutcome) {
        self.result = result
        error = nil
    }

    /// Creates a failed broker reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// A control-endpoint request to resolve a pending wrapper approval.
public struct RuntimeWrapperApprovalDecisionControlRequest: Codable, Equatable, Sendable {
    /// The authenticated control request metadata.
    public let header: APIRequestHeader
    /// The request to allow or deny.
    public let approvalID: ApprovalID
    /// Whether to add the validated wrapper to the registry.
    public let allow: Bool

    /// Creates a wrapper approval decision request.
    public init(
        header: APIRequestHeader,
        approvalID: ApprovalID,
        allow: Bool
    ) {
        self.header = header
        self.approvalID = approvalID
        self.allow = allow
    }
}

/// A control-endpoint request to prepare or retrieve a wrapper approval challenge.
public struct RuntimeWrapperApprovalPrepareControlRequest: Codable, Equatable, Sendable {
    /// The authenticated control request metadata.
    public let header: APIRequestHeader
    /// The absolute path to the wrapper bundle the user chose to approve.
    public let bundlePath: String

    /// Creates a request for a bounded absolute bundle path.
    public init?(header: APIRequestHeader, bundlePath: String) {
        guard RuntimeWrapperApprovalValidation.isAbsolutePath(bundlePath) else {
            return nil
        }
        self.header = header
        self.bundlePath = bundlePath
    }

    private enum CodingKeys: String, CodingKey {
        case header
        case bundlePath
    }

    /// Decodes and validates the bounded bundle path.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let header = try container.decode(APIRequestHeader.self, forKey: .header)
        let bundlePath = try container.decode(String.self, forKey: .bundlePath)
        guard let request = Self(header: header, bundlePath: bundlePath) else {
            throw DecodingError.dataCorruptedError(
                forKey: .bundlePath,
                in: container,
                debugDescription: "Invalid wrapper bundle path."
            )
        }
        self = request
    }
}

/// The validated prompt or typed error returned while preparing wrapper approval.
public struct RuntimeWrapperApprovalPrepareControlReply: Codable, Equatable, Sendable {
    /// The validated prompt, present when approval can be confirmed.
    public let result: RuntimeWrapperApprovalPrompt?
    /// The structured failure, present when the request was rejected.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: RuntimeWrapperApprovalPrompt) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or typed error returned by a wrapper approval decision request.
public struct RuntimeWrapperApprovalDecisionControlReply: Codable, Equatable, Sendable {
    /// An empty result, present when the decision was accepted.
    public let result: RuntimeEmpty?
    /// The structured failure, present when the request was rejected.
    public let error: RuntimeWireError?

    /// Creates a successful decision reply.
    public init(result: RuntimeEmpty = RuntimeEmpty()) {
        self.result = result
        error = nil
    }

    /// Creates a failed decision reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// A wrapper change published on the `wrappers` event topic.
///
/// Future wrapper events decode as ``unknown`` so older clients can keep processing event batches.
public enum WrapperChange: Codable, Equatable, Sendable {
    /// A wrapper is waiting for a user decision.
    case approvalRequested(RuntimeWrapperApprovalPrompt)
    /// A user decision resolved the request.
    case approvalResolved(ApprovalID)
    /// The daemon reported a wrapper event added by a newer API version.
    case unknown

    private enum AssociatedKey: String, CodingKey {
        case first = "_0"
    }

    /// Decodes a wrapper change, preserving future event kinds.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RuntimeWrapperApprovalCodingKey.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected one wrapper change case."
                )
            )
        }
        switch key.stringValue {
        case "approvalRequested":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .approvalRequested(try payload.decode(RuntimeWrapperApprovalPrompt.self, forKey: .first))
        case "approvalResolved":
            let payload = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: key)
            self = .approvalResolved(try payload.decode(ApprovalID.self, forKey: .first))
        default:
            self = .unknown
        }
    }

    /// Encodes a known wrapper change.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RuntimeWrapperApprovalCodingKey.self)
        switch self {
        case .approvalRequested(let prompt):
            try Self.encode(prompt, as: "approvalRequested", into: &container)
        case .approvalResolved(let approvalID):
            try Self.encode(approvalID, as: "approvalResolved", into: &container)
        case .unknown:
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown wrapper events cannot be encoded.")
            )
        }
    }

    private static func encode<Value: Encodable>(
        _ value: Value,
        as caseName: String,
        into container: inout KeyedEncodingContainer<RuntimeWrapperApprovalCodingKey>
    ) throws {
        var payload = container.nestedContainer(
            keyedBy: AssociatedKey.self,
            forKey: RuntimeWrapperApprovalCodingKey(caseName)
        )
        try payload.encode(value, forKey: .first)
    }
}

private enum RuntimeWrapperApprovalValidation {
    static func isAbsolutePath(_ path: String) -> Bool {
        path.first == "/"
            && path.utf8.count <= 4_096
            && !path.utf8.contains(0)
    }

    static func isOptionalAbsolutePath(_ path: String?) -> Bool {
        path.map(isAbsolutePath) ?? true
    }

    static func isBundleID(_ bundleID: String) -> Bool {
        !bundleID.isEmpty
            && bundleID.utf8.count <= 255
            && bundleID.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 || $0 == 46
            }
    }

    static func isDisplayName(_ displayName: String) -> Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && displayName.utf8.count <= 1_024
            && !displayName.utf8.contains(0)
    }

    static func isOptionalVersion(_ version: String?) -> Bool {
        version.map { !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) } ?? true
    }

    static func isTeamIdentifier(_ teamIdentifier: String) -> Bool {
        teamIdentifier.utf8.count == 10
            && teamIdentifier.utf8.allSatisfy {
                (65...90).contains($0) || (48...57).contains($0)
            }
    }
}

private struct RuntimeWrapperApprovalCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}
