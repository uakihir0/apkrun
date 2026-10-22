import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and update app-wide APKRun settings.",
        subcommands: [
            ConfigListCommand.self,
            ConfigGetCommand.self,
            ConfigSetCommand.self,
            ConfigResetCommand.self,
        ]
    )

    mutating func run() async throws {
        Output.write(Self.helpMessage())
    }
}

struct ConfigListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List app-wide settings and their defaults."
    )

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let snapshot = try await client.configuration()
            Output.write(
                json
                    ? try ConfigurationCommandOutput.json(snapshot)
                    : ConfigurationCommandOutput.list(snapshot)
            )
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct ConfigGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Show one app-wide setting."
    )

    @Argument(help: "The dotted setting key.")
    var key: String

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let snapshot = try await client.configuration()
            let entry = try ConfigurationCommandSupport.entry(for: key, in: snapshot)
            Output.write(
                json
                    ? try ConfigurationCommandOutput.json(entry)
                    : ConfigurationCommandOutput.detail(entry)
            )
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct ConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set one app-wide setting."
    )

    @Argument(help: "The dotted setting key.")
    var key: String

    @Argument(help: "The setting value.")
    var value: String

    @Flag(name: .long, help: "Set the value without asking for confirmation.")
    var yes = false

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let current = try await client.configuration()
            let entry = try ConfigurationCommandSupport.entry(for: key, in: current)
            let parsedValue = try ConfigurationCommandSupport.parse(value, for: entry)

            if ConfigurationCommandSupport.requiresSetConfirmation(entry, value: parsedValue) {
                if key == "developer.enabled",
                    parsedValue == JSONValue.bool(true),
                    entry.value != JSONValue.bool(true)
                {
                    try CLIConfirmation.confirm("Enable developer mode?", yes: yes)
                } else {
                    try CLIConfirmation.confirm(
                        ConfigurationCommandOutput.setConfirmation(entry, value: parsedValue),
                        yes: yes
                    )
                }
            }

            let patch = ConfigurationCommandSupport.nestedPatch(for: key, value: parsedValue)
            let updated = try await client.updateConfiguration(ConfigurationPatch(patch: patch))
            Output.write(
                json
                    ? try ConfigurationCommandOutput.json(updated)
                    : ConfigurationCommandOutput.updated(key: key, in: updated)
            )
        } catch let failure as RuntimeWireError {
            throw failure
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct ConfigResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Restore one setting or all resettable settings to their defaults."
    )

    @Argument(help: "The dotted setting key.")
    var key: String?

    @Flag(name: .long, help: "Reset every setting except shared folder roots.")
    var all = false

    @Flag(name: .long, help: "Reset without asking for confirmation.")
    var yes = false

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let target = try ConfigurationCommandSupport.resetTarget(key: key, all: all)
            let client = try RuntimeControlClient(clientKind: .cli)
            let current = try await client.configuration()
            let patch: JSONValue
            switch target {
            case .key(let key):
                let entry = try ConfigurationCommandSupport.entry(for: key, in: current)
                try ConfigurationCommandSupport.requireResettable(key)
                patch = ConfigurationCommandSupport.nestedPatch(for: key, value: .null)
                if entry.isSet {
                    try CLIConfirmation.confirm(
                        ConfigurationCommandOutput.resetConfirmation(entry),
                        yes: yes
                    )
                }
            case .all:
                patch = ConfigurationCommandSupport.resetAllPatch(for: current)
                if current.entries.contains(where: { $0.isSet && $0.key != "sharedFolders.roots" }) {
                    try CLIConfirmation.confirm(
                        "Reset all explicitly set settings to their defaults. Shared folder roots will be kept.",
                        yes: yes
                    )
                }
            }
            let updated = try await client.updateConfiguration(ConfigurationPatch(patch: patch))
            Output.write(
                json
                    ? try ConfigurationCommandOutput.json(updated)
                    : ConfigurationCommandOutput.reset(target: target, in: updated)
            )
        } catch let failure as RuntimeWireError {
            throw failure
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

enum ConfigurationCommandSupport {
    enum ResetTarget: Equatable {
        case key(String)
        case all
    }

    static func entry(for key: String, in snapshot: ConfigurationSnapshot) throws -> ConfigurationEntry {
        guard let entry = snapshot.entries.first(where: { $0.key == key }) else {
            let safeKey = PackageQueryOutput.safeTerminalText(key)
            throw RuntimeWireError.runtime(
                "unknownSetting",
                message: "The setting “\(safeKey)” doesn't exist.",
                remediation: "Run `apkrun config list` to see available settings."
            )
        }
        return entry
    }

    static func parse(_ rawValue: String, for entry: ConfigurationEntry) throws -> JSONValue {
        switch entry.value {
        case .bool:
            return switch rawValue.lowercased() {
            case "true", "on":
                .bool(true)
            case "false", "off":
                .bool(false)
            default:
                throw invalidValue(entry.key, allowed: "true, false, on, off")
            }
        case .integer:
            guard let value = Int64(rawValue) else {
                throw invalidValue(entry.key, allowed: "an integer")
            }
            try validateInteger(value, for: entry.key)
            return .integer(value)
        case .number:
            guard let value = Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX")) else {
                throw invalidValue(entry.key, allowed: "a number")
            }
            return .number(value)
        case .string:
            guard let allowed = enumerationValues[entry.key] else {
                throw invalidValue(entry.key, allowed: "a supported value")
            }
            guard allowed.contains(rawValue) else {
                throw invalidValue(entry.key, allowed: allowed.joined(separator: ", "))
            }
            return .string(rawValue)
        case .null where entry.key == "runtime.userdataGiB":
            guard let value = Int64(rawValue) else {
                throw invalidValue(entry.key, allowed: "an integer")
            }
            try validateInteger(value, for: entry.key)
            return .integer(value)
        case .array, .object, .null:
            throw invalidValue(entry.key, allowed: "Use `apkrun shared-folders` to change shared folders.")
        }
    }

    static func requiresSetConfirmation(_ entry: ConfigurationEntry, value: JSONValue) -> Bool {
        guard entry.isSet, entry.value == value else {
            return true
        }
        // The reported value may be clamped to this Mac's limits while the stored value is larger.
        return ["runtime.cpuCount", "runtime.memoryGiB", "runtime.userdataGiB"].contains(entry.key)
    }

    static func nestedPatch(for key: String, value: JSONValue) -> JSONValue {
        let components = key.split(separator: ".").map(String.init)
        guard let leaf = components.last else {
            return .object([:])
        }
        return .object(nesting(value, under: Array(components.dropLast()), leaf: leaf))
    }

    static func resetAllPatch(for snapshot: ConfigurationSnapshot) -> JSONValue {
        let keys = snapshot.entries
            .filter { $0.isSet && $0.key != "sharedFolders.roots" }
            .map(\.key)
        var patch: [String: JSONValue] = [:]
        for key in keys {
            guard case .object(let nested) = nestedPatch(for: key, value: .null) else { continue }
            merge(nested, into: &patch)
        }
        return .object(patch)
    }

    static func resetTarget(key: String?, all: Bool) throws -> ResetTarget {
        switch (key, all) {
        case (let key?, false):
            .key(key)
        case (nil, true):
            .all
        case (nil, false):
            throw CLIFailure.invalidArgument(argument: "reset", reason: "configurationResetTarget")
        case (_?, true):
            throw CLIFailure.invalidArgument(argument: "reset", reason: "configurationResetTarget")
        }
    }

    static func requireResettable(_ key: String) throws {
        guard key != "sharedFolders.roots" else {
            throw invalidValue(
                "sharedFolders",
                allowed: "Use `apkrun shared-folders` to change shared folders."
            )
        }
    }

    private static let enumerationValues: [String: [String]] = [
        "runtime.startPolicy": ["onDemand", "atLogin"],
        "maintenance.channel": ["stable", "beta"],
        "maintenance.installImages": ["automatic", "ask"],
        "integrations.defaults.links": ["ask", "mac", "android"],
        "integrations.defaults.sharedFolders": ["off", "readOnly", "readWrite"],
        "wrappers.defaultLocation": ["userApplications", "allUsersApplications", "ask"],
    ]

    private static func validateInteger(_ value: Int64, for key: String) throws {
        let allowedValues: [Int64]?
        let range: ClosedRange<Int64>?
        switch key {
        case "runtime.idleSuspendMinutes", "runtime.idleStopMinutes":
            allowedValues = nil
            range = 0...1440
        case "runtime.cpuCount":
            allowedValues = nil
            range = 2...8
        case "runtime.memoryGiB":
            allowedValues = nil
            range = 3...Int64.max
        case "runtime.userdataGiB":
            allowedValues = nil
            range = 8...256
        case "runtime.bootTimeoutSeconds":
            allowedValues = nil
            range = 120...1800
        case "runtime.firstBootTimeoutSeconds":
            allowedValues = nil
            range = 600...3600
        case "display.maxSessions":
            allowedValues = nil
            range = 1...15
        case "updates.checkIntervalHours":
            allowedValues = [1, 3, 6, 12, 24, 72, 168]
            range = nil
        case "graphics.limits.maxDimension":
            allowedValues = nil
            range = 1...16_384
        case let graphicsKey where graphicsKey.hasPrefix("graphics.limits."):
            allowedValues = nil
            range = 1...Int64.max
        default:
            allowedValues = nil
            range = nil
        }

        if let allowedValues, !allowedValues.contains(value) {
            throw invalidValue(key, allowed: allowedValues.map(String.init).joined(separator: ", "))
        }
        if let range, !range.contains(value) {
            let allowed =
                range.upperBound == Int64.max
                ? "≥ \(range.lowerBound)"
                : "\(range.lowerBound)…\(range.upperBound)"
            throw invalidValue(key, allowed: allowed)
        }
    }

    private static func nesting(
        _ value: JSONValue,
        under parents: [String],
        leaf: String
    ) -> [String: JSONValue] {
        guard let parent = parents.first else {
            return [leaf: value]
        }
        return [parent: .object(nesting(value, under: Array(parents.dropFirst()), leaf: leaf))]
    }

    private static func merge(_ source: [String: JSONValue], into destination: inout [String: JSONValue]) {
        for (key, value) in source {
            if case .object(let sourceChildren) = value,
                case .object(let destinationChildren)? = destination[key]
            {
                var children = destinationChildren
                merge(sourceChildren, into: &children)
                destination[key] = .object(children)
            } else {
                destination[key] = value
            }
        }
    }

    private static func invalidValue(_ key: String, allowed: String) -> RuntimeWireError {
        let safeKey = PackageQueryOutput.safeTerminalText(key)
        let safeAllowed = PackageQueryOutput.safeTerminalText(allowed)
        return .runtime(
            "invalidSettingValue",
            message: "The value for “\(safeKey)” is invalid.",
            remediation: "Use one of these values: \(safeAllowed)."
        )
    }
}

enum ConfigurationCommandOutput {
    static func json<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ConfigurationJSONEnvelope(result: value))
        return String(decoding: data, as: UTF8.self)
    }

    static func list(_ snapshot: ConfigurationSnapshot) -> String {
        let entries = snapshot.entries.sorted { $0.key < $1.key }
        let keyWidth = entries.map(\.key.count).max() ?? 0
        let heading = "\(pad("KEY", to: keyWidth))  VALUE  DEFAULT  APPLIES"
        let rows = entries.map { entry in
            "\(pad(entry.key, to: keyWidth))  \(humanValue(entry.value))  "
                + "\(humanValue(entry.defaultValue))  \(appliesName(entry.applies))"
        }
        return ([heading] + rows).joined(separator: "\n")
    }

    static func detail(_ entry: ConfigurationEntry) -> String {
        [
            "\(PackageQueryOutput.safeTerminalText(entry.key)): \(humanValue(entry.value))",
            "Default: \(humanValue(entry.defaultValue))",
            "Set: \(entry.isSet ? "yes" : "no")",
            "Applies: \(appliesName(entry.applies))",
        ].joined(separator: "\n")
    }

    static func updated(key: String, in snapshot: ConfigurationSnapshot) -> String {
        guard let entry = snapshot.entries.first(where: { $0.key == key }) else {
            return "Updated \(PackageQueryOutput.safeTerminalText(key))."
        }
        let lines = ["Set \(PackageQueryOutput.safeTerminalText(key)) to \(humanValue(entry.value))."]
        return (lines + applyHint(entry)).joined(separator: "\n")
    }

    static func setConfirmation(_ entry: ConfigurationEntry, value: JSONValue) -> String {
        let key = PackageQueryOutput.safeTerminalText(entry.key)
        let lines = ["Set \(key) to \(humanValue(value))."]
        return (lines + applyHint(entry)).joined(separator: " ")
    }

    static func resetConfirmation(_ entry: ConfigurationEntry) -> String {
        let key = PackageQueryOutput.safeTerminalText(entry.key)
        let lines = ["Reset \(key) to \(humanValue(entry.defaultValue))."]
        return (lines + applyHint(entry)).joined(separator: " ")
    }

    static func reset(target: ConfigurationCommandSupport.ResetTarget, in snapshot: ConfigurationSnapshot) -> String {
        switch target {
        case .key(let key):
            guard let entry = snapshot.entries.first(where: { $0.key == key }) else {
                return "Reset \(PackageQueryOutput.safeTerminalText(key))."
            }
            let lines = [
                "Reset \(PackageQueryOutput.safeTerminalText(key)) to \(humanValue(entry.value))."
            ]
            return (lines + applyHint(entry)).joined(separator: "\n")
        case .all:
            return "Reset all settings to their defaults. Shared folder roots were kept."
        }
    }

    private static func applyHint(_ entry: ConfigurationEntry) -> [String] {
        switch entry.applies {
        case .live:
            []
        case .nextSession:
            ["Applies the next time the app opens."]
        case .runtimeRestart:
            ["Applies after restarting Android."]
        case .nextCheck:
            ["Applies at the next update check."]
        case .nextLogin:
            ["Applies at the next login."]
        case .newPackages:
            ["Applies to new packages."]
        case .provisioning:
            ["Applies after Reset Android."]
        case .nextBoot:
            ["Applies on the next Android boot."]
        case .nextHealthCheckResult:
            ["Applies after the next app update health check."]
        case .nextUpdate:
            ["Applies at the next app update."]
        case .storedOnly:
            ["Saved, but not applied by this APKRun version."]
        case .unknown:
            []
        }
    }

    private static func appliesName(_ applies: SettingApplies) -> String {
        switch applies {
        case .live: "live"
        case .nextSession: "next session"
        case .runtimeRestart: "runtime restart"
        case .nextCheck: "next check"
        case .nextLogin: "next login"
        case .newPackages: "new packages"
        case .provisioning: "provisioning"
        case .nextBoot: "next boot"
        case .nextHealthCheckResult: "next health-check result"
        case .nextUpdate: "next update"
        case .storedOnly: "stored only"
        case .unknown: "unknown"
        }
    }

    private static func humanValue(_ value: JSONValue) -> String {
        switch value {
        case .null:
            "null"
        case .bool(let value):
            value ? "true" : "false"
        case .integer(let value):
            String(value)
        case .number(let value):
            NSDecimalNumber(decimal: value).stringValue
        case .string(let value):
            PackageQueryOutput.safeTerminalText(value)
        case .array, .object:
            (try? compactJSON(value)) ?? "{}"
        }
    }

    private static func compactJSON(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }
}

private struct ConfigurationJSONEnvelope<Value: Encodable>: Encodable {
    let schemaVersion = 1
    let result: Value
}
