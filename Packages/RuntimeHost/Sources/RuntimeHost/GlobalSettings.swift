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
    /// The dotted keys of the remaining families — `runtime.*`, `display.*`,
    /// `audio.*`, `maintenance.*`, `wrappers.*`, `system.*`, `graphics.*` —
    /// kept verbatim so the Settings panes can read and write them without
    /// a field per key (configuration.md §2).
    public var extras: [String: String]

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
        updatesNotifyInstalled: Bool = false,
        extras: [String: String] = [:]
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
        self.extras = extras
    }

    /// The `settings.json` objects `extras` reads and writes.
    public static let extraFamilies: Set<String> = [
        "runtime", "display", "audio", "maintenance", "wrappers", "system",
        "graphics",
    ]

    /// The defaults `extras` reports for keys the file does not set
    /// (configuration.md §2's "Default" column).
    public static let extraDefaults: [String: String] = [
        "runtime.startPolicy": "onDemand",
        "runtime.idleSuspendMinutes": "10",
        "runtime.idleStopMinutes": "60",
        "runtime.autoRestart": "true",
        "runtime.cpuCount": "4",
        "runtime.memoryGiB": "4",
        "runtime.userdataGiB": "32",
        "display.maxSessions": "8",
        "audio.output": "true",
        "graphics.safeMode": "false",
        "maintenance.checkAutomatically": "true",
        "maintenance.channel": "stable",
        "maintenance.installAPKRunAutomatically": "false",
        "maintenance.downloadImagesAutomatically": "true",
        "maintenance.installImages": "automatic",
        "maintenance.notifyImageInstalled": "false",
        "wrappers.defaultLocation": "userApplications",
        "system.syncLocale": "true",
        "system.syncTimeZone": "true",
        "system.syncClockFormat": "true",
    ]

    /// The effective value of an `extras` key.
    public func extraValue(_ key: String) -> String? {
        extras[key] ?? Self.extraDefaults[key]
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
        var extras: [String: String] = [:]
        for family in Self.extraFamilies {
            guard let raw = object[family] as? [String: Any] else { continue }
            for (name, value) in raw {
                if let flag = value as? Bool {
                    extras["\(family).\(name)"] = flag ? "true" : "false"
                } else if let number = value as? Int {
                    extras["\(family).\(name)"] = String(number)
                } else if let word = value as? String {
                    extras["\(family).\(name)"] = word
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
            updatesNotifyInstalled: updates?["notifyInstalled"] as? Bool ?? false,
            extras: extras)
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
        for (key, value) in settings.extras {
            let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, Self.extraFamilies.contains(parts[0]) else {
                continue
            }
            var family = object[parts[0]] as? [String: Any] ?? [:]
            if value == "true" {
                family[parts[1]] = true
            } else if value == "false" {
                family[parts[1]] = false
            } else if let number = Int(value) {
                family[parts[1]] = number
            } else {
                family[parts[1]] = value
            }
            object[parts[0]] = family
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let temporary = parent.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: fileURL)
        }
    }
}
