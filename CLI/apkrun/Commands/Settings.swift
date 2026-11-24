import ArgumentParser
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun settings <package> list|get|set|reset` (cli.md §4.2,
/// package-metadata-json.md §3): reads and patches the package's
/// `settings.json` over the `packageSettings`/`updatePackageSettings`
/// control operations.
struct SettingsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "Show or change the settings of one Android app.",
        discussion: """
            Usage:
              apkrun settings <package> list [--json]
              apkrun settings <package> get <key>
              apkrun settings <package> set <key> <value>
              apkrun settings <package> reset (<key> | --all)
            """
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Argument(help: "list, get, set, or reset.")
    var action: String

    @Argument(parsing: .remaining, help: "Action arguments: <key> [<value>].")
    var rest: [String] = []

    @Flag(name: .long, help: "Print the result as JSON (list only).")
    var json = false

    @Flag(name: .long, help: "Reset every stored key (reset only).")
    var all = false

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            switch action {
            case "list":
                try await runList(client: client, packageID: packageID)
            case "get":
                try await runGet(client: client, packageID: packageID)
            case "set":
                try await runSet(client: client, packageID: packageID)
            case "reset":
                try await runReset(client: client, packageID: packageID)
            default:
                throw CLIFailure.invalidArgument(
                    argument: action, reason: "expected list, get, set, or reset")
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }

    private func wireSettings(
        client: RuntimeControlClient, packageID: RuntimePackageID
    ) async throws -> PackageSettingsWire {
        guard let settings = try await client.packageSettings(packageID) else {
            throw RuntimeWireError(
                domain: "store", code: "store.packageNotFound",
                message: "APKRun doesn't manage an app named \(packageID.rawValue).",
                parameters: ["package": packageID.rawValue])
        }
        return settings
    }

    private func runList(client: RuntimeControlClient, packageID: RuntimePackageID) async throws {
        let settings = try await wireSettings(client: client, packageID: packageID)
        if json {
            try PackageQueryOutput.writeJSON(settings.entries)
        } else {
            Output.write(SettingsCommandSupport.listText(settings.entries))
        }
    }

    private func runGet(client: RuntimeControlClient, packageID: RuntimePackageID) async throws {
        guard rest.count == 1, let key = rest.first else {
            throw CLIFailure.invalidArgument(
                argument: "get", reason: "expected one setting key")
        }
        let settings = try await wireSettings(client: client, packageID: packageID)
        guard let entry = settings.entries.first(where: { $0.key == key }) else {
            throw SettingsCommand.unknownSetting(key)
        }
        Output.write(entry.value)
    }

    private func runSet(client: RuntimeControlClient, packageID: RuntimePackageID) async throws {
        guard rest.count == 2 else {
            throw CLIFailure.invalidArgument(
                argument: "set", reason: "expected a setting key and a value")
        }
        let key = rest[0]
        var value = rest[1]
        let before = try await wireSettings(client: client, packageID: packageID)
        let entry = before.entries.first { $0.key == key }
        if entry?.allowed == ["true", "false"] {
            if value == "on" { value = "true" }
            if value == "off" { value = "false" }
        }
        let after = try await client.updatePackageSettings(
            packageID, patch: RuntimePackageSettingsPatch(set: [key: value], clear: []))
        Output.write("\(key)=\(value)")
        if entry?.appliesLive == false {
            let name =
                (try? await client.packageInfo(packageID: packageID).summary.displayName)
                ?? packageID.rawValue
            Output.write("Applies the next time \(name) opens.")
        }
        _ = after
    }

    private func runReset(client: RuntimeControlClient, packageID: RuntimePackageID) async throws {
        guard all != (rest.count == 1) else {
            throw CLIFailure.invalidArgument(
                argument: "reset", reason: "expected a setting key or --all")
        }
        let before = try await wireSettings(client: client, packageID: packageID)
        let keys: [String]
        if all {
            keys = before.entries.filter { $0.stored != nil }.map(\.key)
            guard !keys.isEmpty else {
                Output.write("No settings were stored.")
                return
            }
        } else {
            let key = rest[0]
            guard before.entries.contains(where: { $0.key == key }) else {
                throw SettingsCommand.unknownSetting(key)
            }
            keys = [key]
        }
        let after = try await client.updatePackageSettings(
            packageID, patch: RuntimePackageSettingsPatch(set: [:], clear: keys))
        if all {
            Output.write("Reset every stored setting.")
        } else if let entry = after.entries.first(where: { $0.key == keys[0] }) {
            Output.write("\(entry.key)=\(entry.value) (\(entry.source))")
        }
    }

    /// `store.unknownSetting` (cli.md §4.2: unknown keys exit 4).
    static func unknownSetting(_ key: String) -> RuntimeWireError {
        RuntimeWireError(
            domain: "store", code: "store.unknownSetting",
            message: "There is no app setting named \(key).",
            remediation: "List the app's settings with: apkrun settings <package> list",
            parameters: ["key": key])
    }
}

extension SettingsCommand {
    /// The rendering helpers the tests exercise (cli.md §4.2).
    enum SettingsCommandSupport {
        /// `settings list` prints `key=value (source)` per line.
        static func listText(_ entries: [PackageSettingWire]) -> String {
            entries
                .map { "\($0.key)=\($0.value) (\($0.source))" }
                .joined(separator: "\n")
        }
    }
}
