import Foundation

/// The per-package `settings.json` of package-metadata-json.md §3.
///
/// The file stores only values the user changed, as a nested object of the
/// dotted keys (`{"integrations": {"clipboard": false}}`). Keys not present
/// take their documented default; the file is absent for a package the user
/// never configured.
public struct PackageSettings: Codable, Sendable, Equatable {
    /// The `integrations.<name>` values. A JSON boolean or an enum word
    /// (`ask`, `off`, `ro`) is stored as its string form.
    public var integrations: [String: String]
    /// The `update.*` values, notably `mode` (`automatic` | `notifyOnly`,
    /// package-metadata-json.md §3). Absent means the defaults.
    public var update: [String: String]

    /// Creates a settings value.
    public init(integrations: [String: String] = [:], update: [String: String] = [:]) {
        self.integrations = integrations
        self.update = update
    }

    /// The effective `update.mode`; `automatic` unless set to `notifyOnly`.
    public var updateMode: String {
        update["mode"] ?? "automatic"
    }

    /// Decodes a stored settings object; booleans become "true"/"false".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        integrations = [:]
        update = [:]
        if container.contains(.integrations) {
            let nested = try container.nestedContainer(
                keyedBy: DynamicCodingKey.self, forKey: .integrations)
            for key in nested.allKeys {
                if let flag = try? nested.decode(Bool.self, forKey: key) {
                    integrations[key.stringValue] = flag ? "true" : "false"
                } else if let value = try? nested.decode(String.self, forKey: key) {
                    integrations[key.stringValue] = value
                }
            }
        }
        if container.contains(.update) {
            let nested = try container.nestedContainer(
                keyedBy: DynamicCodingKey.self, forKey: .update)
            for key in nested.allKeys {
                if let flag = try? nested.decode(Bool.self, forKey: key) {
                    update[key.stringValue] = flag ? "true" : "false"
                } else if let value = try? nested.decode(String.self, forKey: key) {
                    update[key.stringValue] = value
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case integrations
        case update
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
