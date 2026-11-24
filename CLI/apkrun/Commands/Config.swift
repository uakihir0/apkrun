import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun config` (cli.md §4.6, configuration.md §2.7): group command for
/// the daemon's `updates.*` settings.
struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read and write daemon settings.",
        subcommands: [ConfigGetCommand.self, ConfigSetCommand.self]
    )
}

/// `apkrun config get [<key> …]` (cli.md §4.6): prints `key=value` per
/// setting, one per line; without arguments it prints every `updates.*`
/// key.
struct ConfigGetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Read daemon settings."
    )

    @Argument(help: "The settings keys. Omit to list every `updates.*` key.")
    var keys: [String] = []

    @Flag(name: .long, help: "Print the values as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let values = try await client.getConfig(keys: keys.isEmpty ? nil : keys)
            if json {
                try PackageQueryOutput.writeJSON(values)
            } else {
                for key in values.keys.sorted() {
                    guard let value = values[key] else { continue }
                    Output.write("\(key)=\(value)")
                }
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun config set <key> <value>` (cli.md §4.6): validates and writes
/// one `updates.*` setting.
struct ConfigSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Write a daemon setting."
    )

    @Argument(help: "The settings key, such as updates.checkIntervalHours.")
    var key: String

    @Argument(help: "The new value.")
    var value: String

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let values = try await client.setConfig(key: key, value: value)
            Output.write("\(key)=\(values[key] ?? value)")
            if let note = Self.appliesNote(for: key) {
                Output.write(note)
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }

    /// The "applies at the next start" notice of cli.md §4.6, keyed by the
    /// settings keys that are only read while Android boots.
    static func appliesNote(for key: String) -> String? {
        switch key {
        case "runtime.memoryGiB", "runtime.cpuCount", "audio.output",
            "graphics.safeMode", "developer.enabled":
            return "Applies the next time Android starts."
        case "runtime.userdataGiB":
            return "Applies after Reset Android."
        default:
            return nil
        }
    }
}
