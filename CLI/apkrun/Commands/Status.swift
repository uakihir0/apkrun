import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the Android runtime and open app sessions."
    )

    @Flag(name: .long, help: "Print one JSON document.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.runtimeInfo().status
            let sessions = try await client.listSessions()
            if json {
                Output.write(try StatusCommandOutput.json(status: status, sessions: sessions))
            } else {
                Output.write(StatusCommandOutput.human(status: status, sessions: sessions))
            }
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

enum StatusCommandOutput {
    static func json(status: RuntimeHostStatus, sessions: [SessionSummary]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            StatusCommandEnvelope(result: StatusCommandResult(status: status, sessions: sessions)))
        return String(decoding: data, as: UTF8.self)
    }

    static func human(status: RuntimeHostStatus, sessions: [SessionSummary]) -> String {
        var lines = [
            "Background service: \(PackageQueryOutput.safeTerminalText(status.hostState))",
            "Android: \(PackageQueryOutput.safeTerminalText(status.runtimeState))",
        ]
        if sessions.isEmpty {
            lines.append("Open apps: none")
        } else {
            lines.append("Open apps:")
            for session in sessions {
                lines.append(
                    "  \(PackageQueryOutput.safeTerminalText(session.displayName)) "
                        + "(\(session.packageID.rawValue)) — \(session.state.rawValue)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct StatusCommandEnvelope: Encodable {
    let schemaVersion = 1
    let result: StatusCommandResult
}

private struct StatusCommandResult: Encodable {
    let status: RuntimeHostStatus
    let sessions: [SessionSummary]
}
