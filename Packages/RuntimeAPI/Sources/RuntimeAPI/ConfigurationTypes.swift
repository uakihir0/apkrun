import Foundation

/// A value in the JSON settings wire format.
public enum JSONValue: Codable, Equatable, Sendable {
    /// JSON `null`.
    case null
    /// A JSON Boolean.
    case bool(Bool)
    /// An integral JSON number in the signed 64-bit range.
    case integer(Int64)
    /// A non-integral or out-of-range JSON number.
    case number(Decimal)
    /// A JSON string.
    case string(String)
    /// A JSON array.
    case array([JSONValue])
    /// A JSON object.
    case object([String: JSONValue])

    /// Decodes one JSON value without imposing settings-specific validation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Decimal.self) {
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
                debugDescription: "The value is not valid JSON."
            )
        }
    }

    /// Compares JSON numbers by numeric value even when decoding normalizes an integral number.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            true
        case (.bool(let lhs), .bool(let rhs)):
            lhs == rhs
        case (.integer(let lhs), .integer(let rhs)):
            lhs == rhs
        case (.number(let lhs), .number(let rhs)):
            lhs == rhs
        case (.integer(let lhs), .number(let rhs)):
            Decimal(lhs) == rhs
        case (.number(let lhs), .integer(let rhs)):
            lhs == Decimal(rhs)
        case (.string(let lhs), .string(let rhs)):
            lhs == rhs
        case (.array(let lhs), .array(let rhs)):
            lhs == rhs
        case (.object(let lhs), .object(let rhs)):
            lhs == rhs
        default:
            false
        }
    }

    /// Encodes the corresponding JSON primitive, array, or object.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
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

/// When a configuration setting takes effect.
public enum SettingApplies: String, Codable, Equatable, Sendable {
    /// The change takes effect immediately.
    case live
    /// The change takes effect when the next app session opens.
    case nextSession
    /// The change takes effect after restarting Android.
    case runtimeRestart
    /// The change takes effect at the next update check.
    case nextCheck
    /// The change takes effect at the next user login.
    case nextLogin
    /// The change applies to packages added in the future.
    case newPackages
    /// The change takes effect when Android is provisioned.
    case provisioning
    /// The change takes effect at the next Android boot.
    case nextBoot
    /// The change takes effect after the next health-check result.
    case nextHealthCheckResult
    /// The change takes effect during the next package update.
    case nextUpdate
    /// The value is saved, but this APKRun version does not apply it yet.
    case storedOnly
    /// The server returned an applies value this client does not recognize.
    case unknown

    /// Decodes future applies values as `.unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    /// Encodes the stable wire spelling of this applies value.
    public func encode(to encoder: any Encoder) throws {
        guard self != .unknown else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath, debugDescription: "Unknown applies values cannot be encoded.")
            )
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The resolved value and apply timing for one global configuration key.
public struct ConfigurationEntry: Codable, Equatable, Sendable {
    /// The setting's dotted key, such as `runtime.memoryGiB`.
    public let key: String
    /// The effective value.
    public let value: JSONValue
    /// The setting's default value.
    public let defaultValue: JSONValue
    /// Whether an explicit value is stored, including when it equals the default.
    public let isSet: Bool
    /// When a change to this setting takes effect.
    public let applies: SettingApplies

    /// Creates a resolved global configuration entry.
    public init(
        key: String,
        value: JSONValue,
        defaultValue: JSONValue,
        isSet: Bool,
        applies: SettingApplies
    ) {
        self.key = key
        self.value = value
        self.defaultValue = defaultValue
        self.isSet = isSet
        self.applies = applies
    }
}

/// A snapshot of the resolved global configuration.
public struct ConfigurationSnapshot: Codable, Equatable, Sendable {
    /// The resolved settings, keyed by their dotted names.
    public let entries: [ConfigurationEntry]

    /// Creates a configuration snapshot.
    public init(entries: [ConfigurationEntry]) {
        self.entries = entries
    }
}

/// An RFC 7396 merge patch applied to the nested global settings object.
public struct ConfigurationPatch: Codable, Equatable, Sendable {
    /// The nested JSON merge patch. A `null` member resets that setting.
    public let patch: JSONValue

    /// Creates a global configuration patch.
    public init(patch: JSONValue) {
        self.patch = patch
    }
}

/// Requests the global configuration snapshot through the authenticated control endpoint.
public struct RuntimeConfigurationControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader

    /// Creates a configuration request.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// The result or typed error returned by a global configuration request.
public struct RuntimeConfigurationControlReply: Codable, Equatable, Sendable {
    /// The configuration snapshot, present on success.
    public let result: ConfigurationSnapshot?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: ConfigurationSnapshot) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    /// Decodes exactly one result or error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let result = try container.decodeIfPresent(ConfigurationSnapshot.self, forKey: .result)
        let error = try container.decodeIfPresent(RuntimeWireError.self, forKey: .error)
        guard (result == nil) != (error == nil) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A configuration reply must contain exactly one result or error."
                )
            )
        }
        self.result = result
        self.error = error
    }

    /// Encodes exactly one result or error.
    public func encode(to encoder: any Encoder) throws {
        guard (result == nil) != (error == nil) else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "A configuration reply must contain exactly one result or error."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// Requests an RFC 7396 global configuration update through the authenticated control endpoint.
public struct RuntimeUpdateConfigurationControlRequest: Codable, Equatable, Sendable {
    /// The request metadata.
    public let header: APIRequestHeader
    /// The configuration merge patch.
    public let request: ConfigurationPatch

    /// Creates a configuration update request.
    public init(header: APIRequestHeader, request: ConfigurationPatch) {
        self.header = header
        self.request = request
    }
}

/// The result or typed error returned by a global configuration update.
public struct RuntimeUpdateConfigurationControlReply: Codable, Equatable, Sendable {
    /// The updated configuration snapshot, present on success.
    public let result: ConfigurationSnapshot?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply.
    public init(result: ConfigurationSnapshot) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case error
    }

    /// Decodes exactly one result or error.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let result = try container.decodeIfPresent(ConfigurationSnapshot.self, forKey: .result)
        let error = try container.decodeIfPresent(RuntimeWireError.self, forKey: .error)
        guard (result == nil) != (error == nil) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "A configuration reply must contain exactly one result or error."
                )
            )
        }
        self.result = result
        self.error = error
    }

    /// Encodes exactly one result or error.
    public func encode(to encoder: any Encoder) throws {
        guard (result == nil) != (error == nil) else {
            throw EncodingError.invalidValue(
                self,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "A configuration reply must contain exactly one result or error."
                )
            )
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}
