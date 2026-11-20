import DiagnosticsCore
import Foundation

/// The reader of `dataRoot/settings.json` (configuration.md §1.2).
///
/// apkrund is the only writer; this type reads the global switches other
/// operations gate on. Absent keys mean their defaults: `developer.enabled`
/// defaults to `false`, `integrations.enabled.<name>` to `true`
/// (desktop-integration.md §2.2).
public struct GlobalSettings: Equatable, Sendable {
    /// `developer.enabled` — developer-only requests and UI (diagnostics.md §9.3).
    public var developerEnabled: Bool
    /// `integrations.enabled.<name>` — the global per-integration switch,
    /// keyed by the IntegrationKind name; absent means on.
    public var integrationsEnabled: [String: Bool]
    /// `integrations.defaults.*` — the global default of a per-app switch
    /// (desktop-integration.md §2.2).
    public var integrationsDefaults: [String: String]
    /// `updates.checkIntervalHours` — §2.7, only 1/3/6/12/24/72/168.
    public var updatesCheckIntervalHours: Int
    /// `updates.downloadOnExpensiveNetwork` — §2.7.
    public var updatesDownloadOnExpensiveNetwork: Bool
    /// `updates.startRuntimeToInstall` — §2.7/§3.5.
    public var updatesStartRuntimeToInstall: Bool
    /// `updates.notifyInstalled` — §2.7.
    public var updatesNotifyInstalled: Bool

    /// `updates.checkIntervalHours` allowed values (configuration.md §2.7).
    public static let allowedCheckIntervalHours = [1, 3, 6, 12, 24, 72, 168]
    /// Default `updates.checkIntervalHours`.
    public static let defaultCheckIntervalHours = 6

    /// Creates settings with the given flags.
    public init(
        developerEnabled: Bool = false,
        integrationsEnabled: [String: Bool] = [:],
        integrationsDefaults: [String: String] = [:],
        updatesCheckIntervalHours: Int = GlobalSettings.defaultCheckIntervalHours,
        updatesDownloadOnExpensiveNetwork: Bool = false,
        updatesStartRuntimeToInstall: Bool = false,
        updatesNotifyInstalled: Bool = false
    ) {
        self.developerEnabled = developerEnabled
        self.integrationsEnabled = integrationsEnabled
        self.integrationsDefaults = integrationsDefaults
        self.updatesCheckIntervalHours =
            Self.allowedCheckIntervalHours.contains(updatesCheckIntervalHours)
            ? updatesCheckIntervalHours
            : Self.defaultCheckIntervalHours
        self.updatesDownloadOnExpensiveNetwork = updatesDownloadOnExpensiveNetwork
        self.updatesStartRuntimeToInstall = updatesStartRuntimeToInstall
        self.updatesNotifyInstalled = updatesNotifyInstalled
    }

    /// The global `integrations.enabled.<name>` switch; absent means on.
    public func integrationEnabled(_ name: String) -> Bool {
        integrationsEnabled[name] ?? true
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
        let integrations = object["integrations"] as? [String: Any]
        var enabled: [String: Bool] = [:]
        if let raw = integrations?["enabled"] as? [String: Any] {
            for (name, value) in raw where value is Bool {
                enabled[name] = value as? Bool
            }
        }
        var defaults: [String: String] = [:]
        if let raw = integrations?["defaults"] as? [String: Any] {
            for (name, value) in raw {
                if let flag = value as? Bool {
                    defaults[name] = flag ? "true" : "false"
                } else if let word = value as? String {
                    defaults[name] = word
                }
            }
        }
        let updates = object["updates"] as? [String: Any]
        return GlobalSettings(
            developerEnabled: developer?["enabled"] as? Bool ?? false,
            integrationsEnabled: enabled,
            integrationsDefaults: defaults,
            updatesCheckIntervalHours: updates?["checkIntervalHours"] as? Int
                ?? Self.defaultCheckIntervalHours,
            updatesDownloadOnExpensiveNetwork: updates?["downloadOnExpensiveNetwork"] as? Bool ?? false,
            updatesStartRuntimeToInstall: updates?["startRuntimeToInstall"] as? Bool ?? false,
            updatesNotifyInstalled: updates?["notifyInstalled"] as? Bool ?? false)
    }

    /// Writes `settings.json` atomically (`apkrun config set`), mode 0600. Keys
    /// this type does not model, such as `integrations.*`, are preserved.
    public static func store(_ settings: GlobalSettings, to fileURL: URL) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        var object: [String: Any] = ["schemaVersion": 1]
        if let data = try? Data(contentsOf: fileURL),
            let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            object = existing
        }
        object["developer"] = ["enabled": settings.developerEnabled]
        if !settings.integrationsEnabled.isEmpty || !settings.integrationsDefaults.isEmpty {
            var integrations = object["integrations"] as? [String: Any] ?? [:]
            for (name, value) in settings.integrationsEnabled {
                var enabled = integrations["enabled"] as? [String: Any] ?? [:]
                enabled[name] = value
                integrations["enabled"] = enabled
            }
            for (name, value) in settings.integrationsDefaults {
                var defaults = integrations["defaults"] as? [String: Any] ?? [:]
                defaults[name] = value
                integrations["defaults"] = defaults
            }
            object["integrations"] = integrations
        }
        var updates = object["updates"] as? [String: Any] ?? [:]
        updates["checkIntervalHours"] = settings.updatesCheckIntervalHours
        updates["downloadOnExpensiveNetwork"] = settings.updatesDownloadOnExpensiveNetwork
        updates["startRuntimeToInstall"] = settings.updatesStartRuntimeToInstall
        updates["notifyInstalled"] = settings.updatesNotifyInstalled
        object["updates"] = updates
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = parent.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
    }
}
