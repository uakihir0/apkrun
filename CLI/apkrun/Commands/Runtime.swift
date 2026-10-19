import ArgumentParser
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

struct RuntimeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime",
        abstract: "Inspect and control the Android runtime.",
        subcommands: [RuntimeStatusCommand.self, RuntimeStartCommand.self, RuntimeStopCommand.self],
        defaultSubcommand: RuntimeStatusCommand.self
    )

    mutating func run() async throws {
        Output.write(Self.helpMessage())
    }
}

struct RuntimeStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the background service and Android runtime state."
    )

    @Flag(name: .long, help: "Print one JSON document.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.runtimeStatus()
            if json {
                Output.write(try RuntimeStatusOutput.json(status))
            } else {
                Output.write(RuntimeStatusOutput.human(status))
            }
        } catch {
            throw RuntimeStatusOutput.failure(error)
        }
    }
}

struct RuntimeStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start Android and wait until it is ready."
    )

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.startRuntime()
            Output.write("Android is \(status.runtimeState).")
        } catch {
            throw RuntimeStatusOutput.failure(error)
        }
    }
}

struct RuntimeStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop Android while leaving the background service available."
    )

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.stopRuntime()
            Output.write("Android is \(status.runtimeState).")
        } catch {
            throw RuntimeStatusOutput.failure(error)
        }
    }
}

enum RuntimeStatusOutput {
    static func json(_ status: RuntimeHostStatus) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(RuntimeStatusEnvelope(result: status))
        return String(decoding: data, as: UTF8.self)
    }

    static func human(_ status: RuntimeHostStatus) -> String {
        var lines = [
            "Background service: \(status.hostState)",
            "Android: \(status.runtimeState)",
            "Owner: apkrund",
        ]
        if let progress = status.bootProgress {
            lines.append("Boot progress: \(Int((progress * 100).rounded()))%")
        }
        if let imageVersion = status.imageVersion {
            lines.append("Image: \(imageVersion)")
        }
        if status.crashLoopActive {
            lines.append("Automatic starts are paused after repeated failed starts.")
        }
        if let step = status.startupFailureStep, let code = status.startupFailureCode {
            lines.append("Startup issue: step \(step) (\(code))")
        }
        return lines.joined(separator: "\n")
    }

    static func failure(_ error: any Error) -> RuntimeWireError {
        guard let error = error as? RuntimeControlClientError else {
            return .runtime("internal", message: "APKRun couldn't control the Android runtime.")
        }
        switch error {
        case .invalidClientIdentity:
            return fromCatalog(
                "runtime.notAuthorized",
                fallbackMessage: "This APKRun client can't verify its identity.",
                fallbackRemediation: "Report the problem."
            )
        case .transportFailure:
            return fromCatalog(
                "runtime.serviceUnavailable",
                fallbackMessage: "APKRun's background service isn't running.",
                fallbackRemediation: "Open APKRun once, or restart its background service."
            )
        case .apiVersionMismatch:
            return fromCatalog(
                "runtime.apiVersionMismatch",
                fallbackMessage: "APKRun needs to be restarted.",
                fallbackRemediation: "Quit and reopen APKRun."
            )
        case .remoteFailure(let code, let message):
            return fromCatalog(code, fallbackMessage: message)
        case .endpointRejected(.hostShuttingDown):
            return fromCatalog(
                "runtime.hostShuttingDown",
                fallbackMessage: "APKRun's background service is stopping.",
                fallbackRemediation: "Try again in a moment."
            )
        case .endpointRejected(.malformedRequest):
            return fromCatalog(
                "runtime.malformedRequest",
                fallbackMessage: "APKRun's background service couldn't read the request.",
                fallbackRemediation: "Report the problem."
            )
        case .endpointRejected:
            return fromCatalog(
                "runtime.notAuthorized",
                fallbackMessage: "This part of APKRun isn't allowed to control the runtime.",
                fallbackRemediation: "Report the problem."
            )
        case .malformedReply, .endpointMissing, .invalidRemoteProxy, .encodingFailure, .invalidXPCInterface:
            return fromCatalog(
                "runtime.internal",
                fallbackMessage: "APKRun's background service returned an invalid reply."
            )
        }
    }

    private static func fromCatalog(
        _ code: String,
        fallbackMessage: String,
        fallbackRemediation: String? = nil
    ) -> RuntimeWireError {
        let entry = ErrorCatalog.entry(for: code)
        let catalogMessage = entry?.parameters.isEmpty == true ? entry?.message?["en"] : nil
        return RuntimeWireError(
            domain: String(code.split(separator: ".", maxSplits: 1).first ?? "runtime"),
            code: code,
            message: catalogMessage ?? fallbackMessage,
            remediation: entry?.remediation?["en"] ?? fallbackRemediation
        )
    }
}

private struct RuntimeStatusEnvelope: Encodable {
    let schemaVersion = 1
    let result: RuntimeHostStatus
}
