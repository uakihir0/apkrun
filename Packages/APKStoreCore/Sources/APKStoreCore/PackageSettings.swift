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

    /// Creates a settings value.
    public init(integrations: [String: String] = [:]) {
        self.integrations = integrations
    }

    /// Decodes a stored settings object; booleans become "true"/"false".
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        integrations = [:]
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
    }

    private enum CodingKeys: String, CodingKey {
        case integrations
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
