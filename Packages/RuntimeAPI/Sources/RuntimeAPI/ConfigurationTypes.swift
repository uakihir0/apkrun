import Foundation

/// A JSON value used by global configuration snapshots and merge patches.
public enum JSONValue: Codable, Equatable, Sendable {
    /// JSON null.
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

    /// Creates a JSON value by decoding its JSON representation.
    public init(from decoder: any Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if singleValue.decodeNil() {
            self = .null
        } else if let value = try? singleValue.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? singleValue.decode(Double.self) {
            self = .number(value)
        } else if let value = try? singleValue.decode(String.self) {
            self = .string(value)
        } else if let object = try? decoder.container(keyedBy: JSONValueCodingKey.self) {
            var values: [String: JSONValue] = [:]
            for key in object.allKeys {
                values[key.stringValue] = try object.decode(JSONValue.self, forKey: key)
            }
            self = .object(values)
        } else if var array = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !array.isAtEnd {
                values.append(try array.decode(JSONValue.self))
            }
            self = .array(values)
        } else {
            throw DecodingError.dataCorruptedError(
                in: singleValue,
                debugDescription: "The value is not valid JSON."
            )
        }
    }

    /// Encodes this value as JSON.
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let values):
            var container = encoder.container(keyedBy: JSONValueCodingKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: JSONValueCodingKey(key))
            }
        }
    }
}

private struct JSONValueCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }
}

/// When a global setting takes effect.
public enum SettingApplies: Codable, Equatable, Sendable {
    /// Takes effect immediately.
    case live
    /// Takes effect the next time an app session opens.
    case nextSession
    /// Takes effect after Android restarts.
    case runtimeRestart
    /// Takes effect on the next scheduled or manual check.
    case nextCheck
    /// Takes effect at the next user login.
    case nextLogin
    /// Applies to packages recorded after the change.
    case newPackages
    /// Applies when Android data is provisioned.
    case provisioning
    /// Takes effect on the next Android boot.
    case nextBoot
    /// Applies to the next update health-check result.
    case nextHealthCheckResult
    /// Applies to the next app update.
    case nextUpdate
    /// The server returned an applies value this client does not know.
    case unknown

    /// Creates a setting effect from its wire representation.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "live": self = .live
        case "nextSession": self = .nextSession
        case "runtimeRestart": self = .runtimeRestart
        case "nextCheck": self = .nextCheck
        case "nextLogin": self = .nextLogin
        case "newPackages": self = .newPackages
        case "provisioning": self = .provisioning
        case "nextBoot": self = .nextBoot
        case "nextHealthCheckResult": self = .nextHealthCheckResult
        case "nextUpdate": self = .nextUpdate
        default: self = .unknown
        }
    }

    /// Encodes this setting effect using its wire representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let value: String
        switch self {
        case .live: value = "live"
        case .nextSession: value = "nextSession"
        case .runtimeRestart: value = "runtimeRestart"
        case .nextCheck: value = "nextCheck"
        case .nextLogin: value = "nextLogin"
        case .newPackages: value = "newPackages"
        case .provisioning: value = "provisioning"
        case .nextBoot: value = "nextBoot"
        case .nextHealthCheckResult: value = "nextHealthCheckResult"
        case .nextUpdate: value = "nextUpdate"
        case .unknown: value = "unknown"
        }
        try container.encode(value)
    }
}

/// One global setting and its effective value.
public struct ConfigurationEntry: Codable, Equatable, Sendable {
    /// The dotted setting key.
    public let key: String
    /// The effective setting value.
    public let value: JSONValue
    /// The built-in default value.
    public let defaultValue: JSONValue
    /// Whether the user explicitly stored a value in `settings.json`.
    public let isSet: Bool
    /// When a change to this setting takes effect.
    public let applies: SettingApplies

    /// Creates an entry describing a global setting.
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

/// A snapshot of the effective global configuration.
public struct ConfigurationSnapshot: Codable, Equatable, Sendable {
    /// The global settings implemented by this runtime and their current values.
    public let entries: [ConfigurationEntry]

    /// Creates a snapshot of global configuration entries.
    public init(entries: [ConfigurationEntry]) {
        self.entries = entries
    }
}

/// An RFC 7396 merge patch over the nested global configuration object.
public struct ConfigurationPatch: Codable, Equatable, Sendable {
    /// The nested JSON merge patch. A null value resets that key.
    public let patch: JSONValue

    /// Creates a merge patch for global configuration.
    public init(patch: JSONValue) {
        self.patch = patch
    }
}

/// Requests the current global configuration over the authenticated control endpoint.
public struct RuntimeConfigurationControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader

    /// Creates a request for the current global configuration.
    public init(header: APIRequestHeader) {
        self.header = header
    }
}

/// Updates global configuration over the authenticated control endpoint.
public struct RuntimeUpdateConfigurationControlRequest: Codable, Equatable, Sendable {
    /// The authenticated request metadata.
    public let header: APIRequestHeader
    /// The merge patch to validate and apply.
    public let patch: ConfigurationPatch

    /// Creates a request to update global configuration.
    public init(header: APIRequestHeader, patch: ConfigurationPatch) {
        self.header = header
        self.patch = patch
    }
}

/// The result or structured failure for a configuration request.
public struct RuntimeConfigurationControlReply: Codable, Equatable, Sendable {
    /// The configuration snapshot, present on success.
    public let result: ConfigurationSnapshot?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply containing the current configuration.
    public init(result: ConfigurationSnapshot) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply containing a structured error.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}

/// The result or structured failure for a configuration update request.
public struct RuntimeUpdateConfigurationControlReply: Codable, Equatable, Sendable {
    /// The updated configuration snapshot, present on success.
    public let result: ConfigurationSnapshot?
    /// The structured failure, present on failure.
    public let error: RuntimeWireError?

    /// Creates a successful reply containing the updated configuration.
    public init(result: ConfigurationSnapshot) {
        self.result = result
        error = nil
    }

    /// Creates a failed reply containing a structured error.
    public init(error: RuntimeWireError) {
        result = nil
        self.error = error
    }
}
