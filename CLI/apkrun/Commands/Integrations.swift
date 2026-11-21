import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun integrations`, the desktop-integration commands (FR-CLI-01).
struct IntegrationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "integrations",
        abstract: "Inspect desktop integrations of an Android app.",
        subcommands: [IntegrationsStatusCommand.self]
    )
}

/// `apkrun integrations status <package>`: the effective `integrations.*`
/// values, the §2.3 decisions, and the image support of each kind
/// (runtime-api.md §11).
struct IntegrationsStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the integration settings and decisions of one Android app."
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.integrationStatus(packageID: packageID)
            if json {
                try PackageQueryOutput.writeJSON(status)
            } else {
                for item in status.items {
                    Output.write(IntegrationsStatusOutput.line(item))
                }
                if status.microphoneNeedsRestart {
                    Output.write("microphone: a change waits for an Android restart")
                }
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// The terminal form of one `IntegrationItemStatus` line.
enum IntegrationsStatusOutput {
    /// "clipboard: true (default) — allow — supported (clipboard.text.v1)"
    static func line(_ item: IntegrationItemStatus) -> String {
        var parts = ["\(item.kind.rawValue): \(valueText(item.value)) (\(item.source.rawValue))"]
        parts.append(decisionText(item.decision))
        switch item.support {
        case .supported:
            if let capability = item.capability {
                parts.append("supported (\(capability))")
            } else {
                parts.append("supported")
            }
        case .unsupported:
            parts.append("unsupported (\(item.capability ?? "missing capability"))")
        case .unknown:
            break
        }
        return parts.joined(separator: " — ")
    }

    private static func valueText(_ value: IntegrationValue) -> String {
        switch value {
        case .bool(let flag): return flag ? "true" : "false"
        case .string(let word): return word
        case .null: return "unset"
        }
    }

    private static func decisionText(_ decision: IntegrationStatusDecision) -> String {
        switch decision {
        case .allow: return "allow"
        case .ask: return "ask"
        case .deny(let reason): return "deny (\(reason.rawValue))"
        case .unknown: return "unknown"
        }
    }
}
