import ArgumentParser
import DiagnosticsCore
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

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.startRuntime()
            Output.write("Android is \(status.runtimeState).")
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
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
        abstract: "Reset the Android runtime."
    )

    @Flag(name: .long, help: "Erase all Android data and reinstall managed apps (runtime-daemon.md §9.5).")
    var erase = false

    @Flag(name: .long, help: "Do not keep a 7-day recovery point of Android data.")
    var noBackup = false

    @Flag(name: .long, help: "Erase without typing the confirmation word.")
    var yes = false

    mutating func run() async throws {
        #if !APKRUN_EMBEDDED_RUNTIME
            if erase {
                try await runErase()
                return
            }
        #else
            if erase {
                throw CLIFailure.invalidArgument(
                    argument: "erase",
                    reason: "not available in this build"
                )
            }
        #endif
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.resetRuntime()
            Output.write("Android is \(status.runtimeState). No Android data was deleted.")
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }

    #if !APKRUN_EMBEDDED_RUNTIME
        /// The destructive reset: every Android app, its data, and settings are removed
        /// and managed APKRun apps are reinstalled (runtime-daemon.md §9.5).
        private func runErase() async throws {
            try Self.confirmErase(yes: yes)
            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            let operationID = RuntimeAPI.OperationID()
            let handle = try await client.resetAndroid(
                ResetAndroidRequest(keepBackup: !noBackup, confirmed: true),
                operationID: operationID
            )
            let snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                using: client,
                operationID: handle.operationID,
                progressToStderr: OperationCommandOutput.shouldShowProgress
            )
            guard snapshot.kind == .resetAndroid else {
                throw RuntimeWireError.runtime(
                    "operationResultUnknown",
                    message: "APKRun couldn't read the result of the reset operation."
                )
            }
            try OperationCommandOutput.requireSuccess(snapshot)
            Output.write("Android was reset. Managed apps are being reinstalled.")
        }

        /// The confirmation word the user must type, unless `--yes` was given.
        static func confirmErase(yes: Bool) throws {
            guard !yes else { return }
            guard isatty(STDIN_FILENO) == 1 else {
                throw CLIFailure.confirmationRequired(flag: "--yes")
            }
            FileHandle.standardError.write(
                Data(
                    "This erases all Android apps, their data, and settings. Type \"Reset\" to continue: "
                        .utf8
                )
            )
            guard let answer = readLine(), answer == "Reset" else {
                throw CLIFailure.declined
            }
        }
    #endif
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
        if let provisioning = status.provisioning {
            lines.append("Setup: \(provisioningText(provisioning))")
        }
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

    /// The provisioning line of `apkrun runtime status` (runtime-daemon.md §9.2).
    static func provisioningText(_ state: WireProvisioningState) -> String {
        switch state {
        case .notStarted:
            return "not started"
        case .checkingHost:
            return "checking this Mac"
        case .installingImage(let fraction):
            return "installing image (\(Int((fraction * 100).rounded()))%)"
        case .creatingInstance:
            return "creating the Android instance"
        case .firstBoot(_, let fraction):
            return "first boot (\(Int((fraction * 100).rounded()))%)"
        case .installingAgents:
            return "installing agents"
        case .verifying:
            return "verifying"
        case .complete:
            return "complete"
        case .failed(let step, let error):
            return "failed at \(step.rawValue) (\(error.code))"
        case .unknown:
            return "unknown"
        }
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
    let provisioning: WireProvisioningState?

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
        provisioning = status.provisioning
    }
}
