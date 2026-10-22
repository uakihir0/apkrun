import ArgumentParser
import Darwin
import DiagnosticsCore
import Dispatch
import Foundation
import RuntimeAPI
import RuntimeClient

struct RuntimeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runtime",
        abstract: "Inspect and control the Android runtime.",
        subcommands: [
            RuntimeStatusCommand.self,
            RuntimeStartCommand.self,
            RuntimeStopCommand.self,
            RuntimeRestartCommand.self,
            RuntimeResetCommand.self,
        ],
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
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct RuntimeStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start Android and wait until it is ready."
    )

    @Flag(name: .long, help: "Keep Android ready until this command receives SIGINT or SIGTERM.")
    var hold = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.startRuntime(hold: hold)
            if hold {
                Output.write("Android is \(status.runtimeState). Holding until Ctrl-C or SIGTERM.")
                await RuntimeStartHoldSignalWaiter().wait()
                // The client's XPC connection owns the server-side `.cli` activity hold.
                withExtendedLifetime(client) {}
            } else {
                Output.write("Android is \(status.runtimeState).")
            }
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// Waits for a termination signal while retaining the CLI's runtime-start control connection.
private final class RuntimeStartHoldSignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sources: [DispatchSourceSignal] = []

    func wait() async {
        let previousSIGINTHandler = Darwin.signal(SIGINT, SIG_IGN)
        let previousSIGTERMHandler = Darwin.signal(SIGTERM, SIG_IGN)
        await withCheckedContinuation { continuation in
            let sources = [SIGINT, SIGTERM].map { signalNumber in
                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber,
                    queue: .global(qos: .userInitiated)
                )
                source.setEventHandler { [weak self] in
                    self?.receiveSignal()
                }
                return source
            }
            lock.withLock {
                self.continuation = continuation
                self.sources = sources
            }
            for source in sources {
                source.resume()
            }
        }
        let sources = lock.withLock {
            let sources = self.sources
            self.sources = []
            return sources
        }
        for source in sources {
            source.cancel()
        }
        _ = Darwin.signal(SIGINT, previousSIGINTHandler)
        _ = Darwin.signal(SIGTERM, previousSIGTERMHandler)
    }

    private func receiveSignal() {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
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
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct RuntimeRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart",
        abstract: "Restart Android."
    )

    @Flag(name: .long, help: "Restart without asking for confirmation.")
    var yes = false

    mutating func run() async throws {
        try CLIConfirmation.confirm("Restart the Android runtime?", yes: yes)
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.restartRuntime()
            Output.write("Android is \(status.runtimeState).")
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

struct RuntimeResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Clear the automatic boot-loop guard without deleting Android data."
    )

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.resetRuntime()
            Output.write("Android is \(status.runtimeState). No Android data was deleted.")
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

enum RuntimeStatusOutput {
    static func commandFailure(_ error: any Error) async -> RuntimeWireError {
        guard let clientError = error as? RuntimeControlClientError,
            case .transportFailure = clientError
        else {
            return failure(error)
        }
        let registration = await SystemHostProbe().runtimeRegistration(
            label: BuildInfo.current.launchAgentLabel
        )
        return failure(error, runtimeRegistration: registration)
    }

    static func json(_ status: RuntimeHostStatus) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(RuntimeStatusEnvelope(status: status))
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

    static func failure(
        _ error: any Error,
        runtimeRegistration: HostRuntimeRegistration? = nil
    ) -> RuntimeWireError {
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
            if case .notRegistered? = runtimeRegistration {
                return RuntimeWireError(
                    domain: "runtime",
                    code: "runtime.serviceUnavailable",
                    message: "APKRun's background service is not set up.",
                    remediation: "Open APKRun once, or run: apkrun setup"
                )
            }
            if case .requiresApproval? = runtimeRegistration {
                return RuntimeWireError(
                    domain: "runtime",
                    code: "runtime.serviceUnavailable",
                    message: "APKRun's background service needs approval.",
                    remediation: "Allow APKRun in System Settings under Login Items."
                )
            }
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
        case .requestTimedOut(let operation):
            let failure = fromCatalog(
                "runtime.requestTimedOut",
                fallbackMessage: "APKRun's background service didn't answer in time.",
                fallbackRemediation: "Try again."
            )
            guard operation == "runtimeRestart" else { return failure }
            return RuntimeWireError(
                domain: failure.domain,
                code: failure.code,
                message: failure.message,
                remediation: "Check `apkrun runtime status` before retrying; the daemon may still finish the restart."
            )
        case .operationResultUnknown:
            return fromCatalog(
                "runtime.operationResultUnknown",
                fallbackMessage: "APKRun couldn't confirm whether the install completed.",
                fallbackRemediation: "Check package state before retrying."
            )
        case .requestCancelled:
            return fromCatalog(
                "runtime.cancelled",
                fallbackMessage: "The operation was cancelled."
            )
        case .endpointRejected(.busy):
            return fromCatalog(
                "runtime.busy",
                fallbackMessage: "Android is busy with another task.",
                fallbackRemediation: "Try again when the other requests have finished."
            )
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
    let result: RuntimeStatusResult

    init(status: RuntimeHostStatus) {
        result = RuntimeStatusResult(status: status)
    }
}

private struct RuntimeStatusResult: Encodable {
    let owner = "apkrund"
    let hostState: String
    let runtimeState: String
    let bootProgress: Double?
    let startupFailureStep: Int?
    let startupFailureCode: String?
    let crashLoopActive: Bool
    let daemonPID: Int32
    let imageVersion: String?
    let guestAgentState: GuestAgentConnectionState?
    let guestAgentProtocolVersion: String?

    init(status: RuntimeHostStatus) {
        hostState = status.hostState
        runtimeState = status.runtimeState
        bootProgress = status.bootProgress
        startupFailureStep = status.startupFailureStep
        startupFailureCode = status.startupFailureCode
        crashLoopActive = status.crashLoopActive
        daemonPID = status.daemonPID
        imageVersion = status.imageVersion
        guestAgentState = status.guestAgentState
        guestAgentProtocolVersion = status.guestAgentProtocolVersion
    }
}
