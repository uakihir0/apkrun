import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

struct IntegrationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "integrations",
        abstract: "Inspect Android app integrations.",
        subcommands: [IntegrationsStatusCommand.self]
    )

    mutating func run() async throws {
        Output.write(Self.helpMessage())
    }
}

struct IntegrationsStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show configured and effective integration status for an Android app."
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
                Output.write(try IntegrationStatusCommandOutput.json(status))
            } else {
                Output.write(try IntegrationStatusCommandOutput.human(status))
            }
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

enum IntegrationStatusCommandOutput {
    static func human(_ status: IntegrationStatus) throws -> String {
        var lines = ["Integrations for \(PackageQueryOutput.safeTerminalText(status.packageID.rawValue))"]
        for item in status.items {
            let value = try jsonValue(item.value)
            let source = sourceName(item.source)
            let decision = decisionName(item.decision)
            let support = supportName(item.support)
            let permission = item.macPermission.map { "; macOS permission: \(permissionName($0))" } ?? ""
            lines.append(
                "\(item.kind.rawValue): \(value) (\(source)) — \(decision); \(support)\(permission)"
            )
        }
        if status.microphoneNeedsRestart {
            lines.append("Microphone setting changes take effect after the app restarts.")
        }
        return lines.joined(separator: "\n")
    }

    static func json(_ status: IntegrationStatus) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(IntegrationStatusCommandEnvelope(result: status))
        return String(decoding: data, as: UTF8.self)
    }

    private static func jsonValue(_ value: JSONValue) throws -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return String(value)
        case .string(let value):
            return PackageQueryOutput.safeTerminalText(value)
        case .array, .object:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return PackageQueryOutput.safeTerminalText(String(decoding: data, as: UTF8.self))
        }
    }

    private static func sourceName(_ source: SettingSource) -> String {
        switch source {
        case .globalSwitch: "global switch"
        case .user: "user"
        case .recommended: "recommended"
        case .default: "default"
        }
    }

    private static func decisionName(_ decision: WireIntegrationDecision) -> String {
        switch decision {
        case .allow:
            "allowed"
        case .ask:
            "asks"
        case .deny(let denial):
            "denied (\(denialName(denial)))"
        case .unknown:
            "unknown"
        }
    }

    private static func denialName(_ denial: IntegrationDenial) -> String {
        switch denial {
        case .globallyOff: "globally off"
        case .packageOff: "off for this package"
        case .notFocused: "app is not focused"
        case .noSession: "no running session"
        case .notSupported(let capability):
            "unsupported: \(PackageQueryOutput.safeTerminalText(capability))"
        case .rateLimited: "rate limited"
        }
    }

    private static func supportName(_ support: IntegrationSupport) -> String {
        switch support {
        case .supported:
            "supported"
        case .unsupported(let capability):
            "unsupported (\(PackageQueryOutput.safeTerminalText(capability)))"
        case .unknown:
            "support unknown"
        }
    }

    private static func permissionName(_ permission: MacPermissionState) -> String {
        switch permission {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        case .unknown: "unknown"
        }
    }
}

private struct IntegrationStatusCommandEnvelope: Encodable {
    let schemaVersion = 1
    let result: IntegrationStatus
}
