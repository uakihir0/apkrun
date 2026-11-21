import Foundation

/// A per-package setting value in its stored string form: `true`, `480`,
/// `1.25`, or an enum word such as `secondaryDisplay`.
public struct PackageSettings: Codable, Sendable, Equatable {
    /// Stored values per top-level group (`window`, `input`, `integrations`,
    /// `update`), each mapping a leaf key to its string form.
    public var groups: [String: [String: String]]

    /// Creates an empty settings value.
    public init(groups: [String: [String: String]] = [:]) {
        self.groups = groups
    }

    /// The stored value of a dotted key, nil when absent.
    public func value(_ key: String) -> String? {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return groups[parts[0]]?[parts[1]]
    }

    /// Applies one patch element: `nil` removes the stored value (Reset).
    /// Unknown groups or keys are ignored — readers validate key by key.
    public mutating func set(_ key: String, _ value: String?) {
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if let value {
            groups[parts[0], default: [:]][parts[1]] = value
        } else {
            groups[parts[0]]?.removeValue(forKey: parts[1])
            if groups[parts[0]]?.isEmpty == true {
                groups.removeValue(forKey: parts[0])
            }
        }
    }

    /// The effective `update.mode`; `automatic` unless set to `notifyOnly`.
    public var updateMode: String {
        value("update.mode") ?? "automatic"
    }

    /// The `update.*` group (compatibility with earlier callers).
    public var update: [String: String] {
        groups["update"] ?? [:]
    }

    /// The `integrations.*` group (compatibility with earlier callers).
    public var integrations: [String: String] {
        groups["integrations"] ?? [:]
    }

    /// The JSON object written to `settings.json` (package-metadata-json.md
    /// §3.2): string forms become typed scalars via `PackageSettingsSchema`.
    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["schemaVersion": 1]
        for (group, entries) in groups where !entries.isEmpty {
            var nested: [String: Any] = [:]
            for (leaf, stored) in entries {
                let key = "\(group).\(leaf)"
                nested[leaf] = PackageSettingsSchema.scalar(for: key, stored: stored) ?? stored
            }
            object[group] = nested
        }
        return object
    }

    /// Reads a nested settings object, converting scalars to string form.
    public init(jsonObject object: [String: Any]) {
        var groups: [String: [String: String]] = [:]
        for (group, value) in object where group != "schemaVersion" {
            guard let nested = value as? [String: Any] else { continue }
            for (leaf, scalar) in nested {
                let key = "\(group).\(leaf)"
                if let stored = PackageSettingsSchema.stringForm(for: key, scalar: scalar) {
                    groups[group, default: [:]][leaf] = stored
                }
            }
        }
        self.groups = groups
    }

    /// Decodes a stored settings object.
    /// Decodes a scalar or nested object from the settings JSON blob.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: JSONSettingScalar].self) {
            var groups: [String: [String: String]] = [:]
            for (group, scalar) in object where group != "schemaVersion" {
                guard case .object(let nested) = scalar else { continue }
                for (leaf, leafScalar) in nested {
                    if let stored = leafScalar.stringForm {
                        groups[group, default: [:]][leaf] = stored
                    }
                }
            }
            groups = groups.filter { !$0.value.isEmpty }
            self.groups = groups
        } else {
            self.groups = [:]
        }
    }

    /// Encodes the nested storage object.
    /// Encodes back to the scalar or nested object form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        var object: [String: JSONSettingScalar] = ["schemaVersion": .int(1)]
        for (group, entries) in groups where !entries.isEmpty {
            var nested: [String: JSONSettingScalar] = [:]
            for (leaf, stored) in entries {
                let key = "\(group).\(leaf)"
                nested[leaf] = PackageSettingsSchema.scalarValue(for: key, stored: stored)
            }
            object[group] = .object(nested)
        }
        try container.encode(object)
    }
}

/// A JSON scalar for `settings.json` round trips.
public enum JSONSettingScalar: Codable, Sendable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case object([String: JSONSettingScalar])

    /// The stored string form.
    public var stringForm: String? {
        switch self {
        case .bool(let flag): flag ? "true" : "false"
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .string(let word): word
        case .object: nil
        }
    }

    /// Decodes a scalar or nested object from the settings JSON blob.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .bool(flag)
        } else if let number = try? container.decode(Int.self) {
            self = .int(number)
        } else if let number = try? container.decode(Double.self) {
            self = .double(number)
        } else if let word = try? container.decode(String.self) {
            self = .string(word)
        } else {
            self = .object(try container.decode([String: JSONSettingScalar].self))
        }
    }

    /// Encodes back to the scalar or nested object form.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try container.encode(flag)
        case .int(let number): try container.encode(number)
        case .double(let number): try container.encode(number)
        case .string(let word): try container.encode(word)
        case .object(let nested): try container.encode(nested)
        }
    }
}

/// The `settings.json` key table of package-metadata-json.md §3.1: what each
/// key accepts, its built-in default, and when it applies.
public enum PackageSettingsSchema {
    /// A key's value kind.
    public enum Kind: Sendable {
        /// `true` / `false`.
        case flag
        /// An integer inside a closed range.
        case integer(ClosedRange<Int>)
        /// A number inside a closed range.
        case number(ClosedRange<Double>)
        /// One of the listed words.
        case word([String])
    }

    /// One row of §3.1.
    public struct Key: Sendable {
        /// Dotted key within the group, e.g. `window.resizable`.
        public let name: String
        /// Value kind that drives parsing and validation.
        public let kind: Kind
        /// The built-in default in string form (rule 4 of §3.2).
        public let builtInDefault: String
        /// `true` when a change applies without a new session (`live`).
        public let appliesLive: Bool

        /// Creates a key row.
        public init(name: String, kind: Kind, builtInDefault: String, appliesLive: Bool) {
            self.name = name
            self.kind = kind
            self.builtInDefault = builtInDefault
            self.appliesLive = appliesLive
        }
    }

    /// Every §3.1 key.
    public static let keys: [Key] = [
        Key(
            name: "window.mode", kind: .word(["secondaryDisplay", "primaryDisplayCompatibility"]),
            builtInDefault: "secondaryDisplay", appliesLive: false),
        Key(
            name: "window.defaultWidth", kind: .integer(320...8192),
            builtInDefault: "480", appliesLive: false),
        Key(
            name: "window.defaultHeight", kind: .integer(400...8192),
            builtInDefault: "850", appliesLive: false),
        Key(name: "window.resizable", kind: .flag, builtInDefault: "true", appliesLive: true),
        Key(name: "window.alwaysOnTop", kind: .flag, builtInDefault: "false", appliesLive: true),
        Key(
            name: "window.zoom", kind: .number(0.75...2.0),
            builtInDefault: "1.0", appliesLive: true),
        Key(
            name: "window.closeBehavior", kind: .word(["stop", "keepRunning"]),
            builtInDefault: "stop", appliesLive: true),
        Key(
            name: "input.escapeKey", kind: .word(["back", "escape"]),
            builtInDefault: "back", appliesLive: false),
        Key(
            name: "input.secondaryClick", kind: .word(["mouseSecondary", "longPress"]),
            builtInDefault: "mouseSecondary", appliesLive: false),
        Key(
            name: "input.scrollMode", kind: .word(["scroll", "touchDrag"]),
            builtInDefault: "scroll", appliesLive: false),
        Key(name: "input.hover", kind: .flag, builtInDefault: "true", appliesLive: false),
        Key(name: "input.sendCommandKey", kind: .flag, builtInDefault: "false", appliesLive: false),
        Key(name: "integrations.clipboard", kind: .flag, builtInDefault: "true", appliesLive: true),
        Key(name: "integrations.notifications", kind: .flag, builtInDefault: "true", appliesLive: true),
        Key(
            name: "integrations.links", kind: .word(["ask", "mac", "android"]),
            builtInDefault: "ask", appliesLive: true),
        Key(name: "integrations.files", kind: .flag, builtInDefault: "true", appliesLive: true),
        Key(
            name: "integrations.sharedFolders", kind: .word(["off", "readOnly", "readWrite"]),
            builtInDefault: "off", appliesLive: true),
        Key(name: "integrations.microphone", kind: .flag, builtInDefault: "false", appliesLive: true),
        Key(
            name: "update.mode", kind: .word(["automatic", "notifyOnly"]),
            builtInDefault: "automatic", appliesLive: false),
        Key(name: "update.autoRollback", kind: .flag, builtInDefault: "true", appliesLive: false),
        Key(name: "update.healthCheckLaunch", kind: .flag, builtInDefault: "true", appliesLive: false),
    ]

    /// The schema row of a dotted key, nil when unknown.
    public static func key(_ name: String) -> Key? {
        keys.first { $0.name == name }
    }

    /// Whether `stored` is an allowed value for `name` (§3.1).
    public static func isValid(_ name: String, stored: String) -> Bool {
        guard let key = key(name) else { return false }
        switch key.kind {
        case .flag:
            return stored == "true" || stored == "false"
        case .integer(let range):
            guard let number = Int(stored) else { return false }
            return range.contains(number)
        case .number(let range):
            guard let number = Double(stored) else { return false }
            return range.contains(number)
        case .word(let words):
            return words.contains(stored)
        }
    }

    /// The allowed values of a key for CLI error output, nil when free-form.
    public static func allowedValues(_ name: String) -> String? {
        guard let key = key(name) else { return nil }
        switch key.kind {
        case .flag:
            return "true, false"
        case .integer(let range):
            return "\(range.lowerBound)…\(range.upperBound)"
        case .number(let range):
            return "\(range.lowerBound)…\(range.upperBound)"
        case .word(let words):
            return words.joined(separator: ", ")
        }
    }

    /// Converts a stored string to its JSON scalar (§3.2).
    static func scalar(for key: String, stored: String) -> Any? {
        scalarValue(for: key, stored: stored).jsonValue
    }

    /// Converts a stored string to a `JSONSettingScalar`.
    static func scalarValue(for key: String, stored: String) -> JSONSettingScalar {
        guard let entry = self.key(key) else { return .string(stored) }
        switch entry.kind {
        case .flag:
            return .bool(stored == "true")
        case .integer:
            return .int(Int(stored) ?? 0)
        case .number:
            return .double(Double(stored) ?? 0)
        case .word:
            return .string(stored)
        }
    }

    /// Converts a JSON scalar to its stored string form for a known key.
    static func stringForm(for key: String, scalar: Any) -> String? {
        guard let entry = self.key(key) else { return nil }
        switch entry.kind {
        case .flag:
            guard let flag = scalar as? Bool else { return nil }
            return flag ? "true" : "false"
        case .integer:
            if let number = scalar as? Int { return String(number) }
            return nil
        case .number:
            if let number = scalar as? Double { return String(number) }
            if let number = scalar as? Int { return String(number) }
            return nil
        case .word:
            return scalar as? String
        }
    }
}

extension JSONSettingScalar {
    /// The Foundation JSON value.
    var jsonValue: Any {
        switch self {
        case .bool(let flag): flag
        case .int(let number): number
        case .double(let number): number
        case .string(let word): word
        case .object(let nested):
            nested.mapValues { $0.jsonValue }
        }
    }
}

/// Resolves the effective value of every §3.1 key (configuration.md §3.2):
/// a forced-off global switch wins, then the stored value, then a
/// compatibility recommendation (#91), then the built-in default.
public struct PackageSettingsResolver: Sendable {
    /// `integrations.enabled.<name>` of the global settings; absent means on.
    public var globalIntegrationsEnabled: [String: Bool]
    /// Compatibility-database recommendations for this package (#91), keyed
    /// by setting name. Empty until the database exists.
    public var recommendations: [String: String]

    /// Creates a resolved package settings view.
    public init(
        globalIntegrationsEnabled: [String: Bool] = [:],
        recommendations: [String: String] = [:]
    ) {
        self.globalIntegrationsEnabled = globalIntegrationsEnabled
        self.recommendations = recommendations
    }

    /// The effective string form of a key.
    public func effectiveValue(for key: String, in settings: PackageSettings?) -> String {
        if key.hasPrefix("integrations."),
            globalIntegrationsEnabled[String(key.dropFirst("integrations.".count))] == false
        {
            return "false"
        }
        if let stored = settings?.value(key) { return stored }
        if let recommendation = recommendations[key] { return recommendation }
        return PackageSettingsSchema.key(key)?.builtInDefault ?? ""
    }

    /// Whether a key's effective value comes from the compatibility
    /// database (the UI marks it "Recommended for this app").
    public func isRecommended(_ key: String, in settings: PackageSettings?) -> Bool {
        settings?.value(key) == nil && recommendations[key] != nil
    }
}
