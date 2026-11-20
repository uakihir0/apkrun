import DiagnosticsCore
import Foundation

/// The reader of `dataRoot/settings.json` (configuration.md §1.2).
///
/// apkrund is the only writer; this type reads the global switches other
/// operations gate on. Absent keys mean their defaults: `developer.enabled`
/// defaults to `false`.
public struct GlobalSettings: Equatable, Sendable {
    /// `developer.enabled` — developer-only requests and UI (diagnostics.md §9.3).
    public var developerEnabled: Bool

    /// Creates settings with the given flags.
    public init(developerEnabled: Bool = false) {
        self.developerEnabled = developerEnabled
    }

    /// Reads `settings.json`; a missing or malformed file yields the defaults.
    public static func load(from fileURL: URL) -> GlobalSettings {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return GlobalSettings()
        }
        let developer = object["developer"] as? [String: Any]
        return GlobalSettings(developerEnabled: developer?["enabled"] as? Bool ?? false)
    }

    /// Writes `settings.json` atomically (`apkrun config set`), mode 0600.
    public static func store(_ settings: GlobalSettings, to fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let object: [String: Any] = [
            "schemaVersion": 1,
            "developer": ["enabled": settings.developerEnabled],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = parent.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
    }
}
