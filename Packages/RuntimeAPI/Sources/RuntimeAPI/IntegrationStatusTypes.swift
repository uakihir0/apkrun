import Foundation

/// A JSON-compatible setting value returned by `integrationStatus`.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    /// A JSON null.
    case null
    /// A JSON boolean.
    case bool(Bool)
    /// A JSON number.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object.
    case object([String: JSONValue])

    /// Decodes any JSON-compatible value.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Value is not JSON-compatible."
            )
        }
    }

    /// Encodes this JSON-compatible value.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// The integration whose effective setting is shown in `IntegrationStatus`.
public enum IntegrationKind: String, Codable, CaseIterable, Sendable {
    /// Clipboard access between the Mac and Android.
    case clipboard
    /// Android notification mirroring.
    case notifications
    /// Opening supported links in Android apps.
    case links
    /// Importing and exporting files.
    case files
    /// Access to the configured shared folders.
    case sharedFolders
    /// Microphone input for Android apps.
    case microphone
}

/// Where an integration setting came from.
public enum SettingSource: String, Codable, Sendable {
    /// The value comes from a global integration switch.
    case globalSwitch
    /// The value was selected for this package.
    case user
    /// The value comes from a recommended setting.
    case recommended
    /// The value comes from the documented default.
    case `default`
}

/// A reason an integration is denied by policy.
public enum IntegrationDenial: Equatable, Sendable {
    /// A global switch disables this integration.
    case globallyOff
    /// The package setting disables this integration.
    case packageOff
    /// The package does not currently own input focus.
    case notFocused
    /// The package has no active runtime session.
    case noSession
    /// The installed image does not implement the required capability.
    case notSupported(capability: String)
    /// The package exceeded the integration's rate limit.
    case rateLimited
}

/// The effective result of applying integration policy.
public enum WireIntegrationDecision: Equatable, Sendable {
    /// The operation is permitted by current policy.
    case allow
    /// The operation requires a user decision.
    case ask
    /// The operation is refused for the associated reason.
    case deny(IntegrationDenial)
    /// The decision was added by a newer API version.
    case unknown
}

extension WireIntegrationDecision: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case denial
        case capability
    }

    private enum Kind: String, Codable {
        case allow
        case ask
        case deny
        case unknown
    }

    private enum DenialKind: String, Codable {
        case globallyOff
        case packageOff
        case notFocused
        case noSession
        case notSupported
        case rateLimited
    }

    /// Decodes a known policy decision, preserving future decisions as `unknown`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try? container.decode(Kind.self, forKey: .kind) else {
            self = .unknown
            return
        }
        switch kind {
        case .allow:
            self = .allow
        case .ask:
            self = .ask
        case .unknown:
            self = .unknown
        case .deny:
            guard let denial = try? container.decode(DenialKind.self, forKey: .denial) else {
                self = .unknown
                return
            }
            switch denial {
            case .globallyOff:
                self = .deny(.globallyOff)
            case .packageOff:
                self = .deny(.packageOff)
            case .notFocused:
                self = .deny(.notFocused)
            case .noSession:
                self = .deny(.noSession)
            case .notSupported:
                let capability = try container.decode(String.self, forKey: .capability)
                self = .deny(.notSupported(capability: capability))
            case .rateLimited:
                self = .deny(.rateLimited)
            }
        }
    }

    /// Encodes this policy decision.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allow:
            try container.encode(Kind.allow, forKey: .kind)
        case .ask:
            try container.encode(Kind.ask, forKey: .kind)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        case .deny(let denial):
            try container.encode(Kind.deny, forKey: .kind)
            switch denial {
            case .globallyOff:
                try container.encode(DenialKind.globallyOff, forKey: .denial)
            case .packageOff:
                try container.encode(DenialKind.packageOff, forKey: .denial)
            case .notFocused:
                try container.encode(DenialKind.notFocused, forKey: .denial)
            case .noSession:
                try container.encode(DenialKind.noSession, forKey: .denial)
            case .notSupported(let capability):
                try container.encode(DenialKind.notSupported, forKey: .denial)
                try container.encode(capability, forKey: .capability)
            case .rateLimited:
                try container.encode(DenialKind.rateLimited, forKey: .denial)
            }
        }
    }
}

/// Whether the installed Android image implements an integration capability.
public enum IntegrationSupport: Equatable, Sendable {
    /// The installed image supports the integration.
    case supported
    /// The installed image lacks the named capability.
    case unsupported(capability: String)
    /// Support could not be determined.
    case unknown
}

extension IntegrationSupport: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case capability
    }

    private enum Kind: String, Codable {
        case supported
        case unsupported
        case unknown
    }

    /// Decodes known support metadata, preserving future values as `unknown`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = try? container.decode(Kind.self, forKey: .kind) else {
            self = .unknown
            return
        }
        switch kind {
        case .supported:
            self = .supported
        case .unsupported:
            self = .unsupported(capability: try container.decode(String.self, forKey: .capability))
        case .unknown:
            self = .unknown
        }
    }

    /// Encodes this support metadata.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .supported:
            try container.encode(Kind.supported, forKey: .kind)
        case .unsupported(let capability):
            try container.encode(Kind.unsupported, forKey: .kind)
            try container.encode(capability, forKey: .capability)
        case .unknown:
            try container.encode(Kind.unknown, forKey: .kind)
        }
    }
}

/// A permission state reported by macOS for an integration.
public enum MacPermissionState: String, Codable, Sendable {
    /// macOS has not prompted for this permission.
    case notDetermined
    /// macOS denied this permission.
    case denied
    /// Policy prevents this permission from being granted.
    case restricted
    /// macOS authorized this permission.
    case authorized
    /// macOS granted provisional authorization.
    case provisional
    /// macOS granted temporary authorization.
    case ephemeral
    /// The permission state is unknown or was added by a newer OS.
    case unknown
}

/// One integration's configured and effective status.
public struct IntegrationItemStatus: Codable, Equatable, Sendable {
    /// The integration represented by this item.
    public let kind: IntegrationKind
    /// The configured value, preserving its JSON shape.
    public let value: JSONValue
    /// Where the configured value came from.
    public let source: SettingSource
    /// The effective decision after host policy is applied.
    public let decision: WireIntegrationDecision
    /// Whether the installed Android image supports the integration.
    public let support: IntegrationSupport
    /// The permission state reported by macOS, when applicable.
    public let macPermission: MacPermissionState?

    /// Creates an integration status item.
    public init(
        kind: IntegrationKind,
        value: JSONValue,
        source: SettingSource,
        decision: WireIntegrationDecision,
        support: IntegrationSupport,
        macPermission: MacPermissionState? = nil
    ) {
        self.kind = kind
        self.value = value
        self.source = source
        self.decision = decision
        self.support = support
        self.macPermission = macPermission
    }
}

/// The current integration settings and effective policy for one package.
public struct IntegrationStatus: Codable, Equatable, Sendable {
    /// The package whose settings are reported.
    public let packageID: RuntimePackageID
    /// The configured values and effective decisions for each integration.
    public let items: [IntegrationItemStatus]
    /// Whether changing microphone settings requires an Android restart.
    public let microphoneNeedsRestart: Bool

    /// Creates integration status for a package.
    public init(
        packageID: RuntimePackageID,
        items: [IntegrationItemStatus],
        microphoneNeedsRestart: Bool = false
    ) {
        self.packageID = packageID
        self.items = items
        self.microphoneNeedsRestart = microphoneNeedsRestart
    }
}

/// Reads the effective integration status for one package through the control endpoint.
public struct RuntimeIntegrationStatusControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The package whose integration settings are requested.
    public let packageID: RuntimePackageID

    /// Creates an integration-status query.
    public init(header: APIRequestHeader, packageID: RuntimePackageID) {
        self.header = header
        self.packageID = packageID
    }
}

/// The result of an integration-status query.
public struct RuntimeIntegrationStatusControlReply: Codable, Equatable, Sendable {
    /// The status result, or nil when the request failed.
    public let result: IntegrationStatus?
    /// The typed error, or nil when the request succeeded.
    public let error: RuntimeWireError?

    /// Creates a successful integration-status reply.
    public init(result: IntegrationStatus) {
        self.result = result
        error = nil
    }

    /// Creates a failed integration-status reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}
