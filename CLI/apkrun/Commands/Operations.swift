#if !APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Darwin
    import Dispatch
    import Foundation
    import RuntimeAPI
    import RuntimeClient

    struct OperationsCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "operations",
            abstract: "Inspect or cancel long-running APKRun operations.",
            subcommands: [
                OperationsListCommand.self,
                OperationsWaitCommand.self,
                OperationsCancelCommand.self,
            ]
        )

        mutating func run() async throws {
            Output.write(Self.helpMessage())
        }
    }

    struct OperationsListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List running and recently completed operations."
        )

        @Flag(name: .long, help: "Print one JSON document.")
        var json = false

        mutating func run() async throws {
            do {
                let client = try RuntimeControlClient(clientKind: .cli)
                let operations = try await client.listOperations()
                if json {
                    try OperationCommandOutput.writeJSON(operations)
                } else {
                    Output.write(OperationCommandOutput.listText(operations))
                }
            } catch {
                throw await OperationCommandOutput.commandFailure(error)
            }
        }
    }

    struct OperationsWaitCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wait",
            abstract: "Wait for an operation to finish."
        )

        @Argument(help: "The operation ID.")
        var id: String

        @Flag(name: .long, help: "Print one JSON document.")
        var json = false

        @Flag(name: .long, help: "Return after checking the current state; the operation keeps running.")
        var detach = false

        mutating func run() async throws {
            let operationID = try OperationCommandOutput.parseOperationID(id)
            do {
                let client = try RuntimeControlClient(clientKind: .cli)
                let snapshot: OperationSnapshot
                if detach {
                    snapshot = try await client.operationStatus(operationID)
                    guard snapshot.operationID == operationID else {
                        throw OperationCommandOutput.unknownResultError(operationID)
                    }
                } else {
                    snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                        using: client,
                        operationID: operationID,
                        progressToStderr: OperationCommandOutput.shouldShowProgress
                    )
                }
                if snapshot.result != nil {
                    try OperationCommandOutput.requireSuccess(snapshot)
                }
                if json {
                    try OperationCommandOutput.writeJSON(snapshot)
                } else {
                    Output.write(
                        detach && snapshot.result == nil
                            ? OperationCommandOutput.detachedText(snapshot)
                            : OperationCommandOutput.completionText(snapshot))
                }
            } catch {
                throw await OperationCommandOutput.commandFailure(error)
            }
        }
    }

    struct OperationsCancelCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "cancel",
            abstract: "Request cancellation of an operation."
        )

        @Argument(help: "The operation ID.")
        var id: String

        @Flag(name: .long, help: "Print one JSON document.")
        var json = false

        mutating func run() async throws {
            let operationID = try OperationCommandOutput.parseOperationID(id)
            do {
                let client = try RuntimeControlClient(clientKind: .cli)
                let result = try await client.cancelOperation(operationID)
                try OperationCommandOutput.checkCancelResult(result)
                if json {
                    try OperationCommandOutput.writeJSON(
                        OperationCancelEnvelope(operationID: operationID, result: result)
                    )
                } else {
                    Output.write(OperationCommandOutput.cancelText(operationID, result: result))
                }
            } catch {
                throw await OperationCommandOutput.commandFailure(error)
            }
        }
    }

    enum OperationCommandOutput {
        // REVIEW REQUIRED (IR-1391): Operation events are not exposed to this CLI slice yet.
        // Polling every two seconds keeps idle XPC traffic modest while keeping status responsive.
        // Progress is written only to an interactive stderr so noninteractive output stays stable.
        static let pollingInterval = Duration.seconds(2)
        static let maximumConsecutiveStatusFailures = 4

        static var shouldShowProgress: Bool {
            isatty(STDERR_FILENO) == 1
        }

        static func parseOperationID(_ value: String) throws -> OperationID {
            guard let operationID = OperationID(wire: value) else {
                throw CLIFailure.invalidArgument(argument: "operation", reason: "id")
            }
            return operationID
        }

        static func waitForTerminalSnapshot(
            using client: RuntimeControlClient,
            operationID: OperationID,
            progressToStderr: Bool
        ) async throws -> OperationSnapshot {
            try await waitForTerminalSnapshot(
                operationID: operationID,
                progressToStderr: progressToStderr,
                query: { id in
                    try await client.operationStatus(id)
                },
                cancel: {
                    _ = try? await client.cancelOperation(operationID)
                }
            )
        }

        static func waitForTerminalSnapshot(
            operationID: OperationID,
            progressToStderr: Bool,
            pollInterval: Duration = pollingInterval,
            maximumConsecutiveFailures: Int = maximumConsecutiveStatusFailures,
            query: @escaping @Sendable (OperationID) async throws -> OperationSnapshot,
            cancel: @escaping @Sendable () async -> Void = {},
            sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
                try await Task.sleep(for: duration)
            }
        ) async throws -> OperationSnapshot {
            let signalMonitor = OperationSignalMonitor {
                Task {
                    await cancel()
                }
            }
            return try await waitForTerminalSnapshot(
                operationID: operationID,
                progressToStderr: progressToStderr,
                pollInterval: pollInterval,
                maximumConsecutiveFailures: maximumConsecutiveFailures,
                query: query,
                sleep: sleep,
                signalMonitor: signalMonitor
            )
        }

        private static func waitForTerminalSnapshot(
            operationID: OperationID,
            progressToStderr: Bool,
            pollInterval: Duration,
            maximumConsecutiveFailures: Int,
            query: @escaping @Sendable (OperationID) async throws -> OperationSnapshot,
            sleep: @escaping @Sendable (Duration) async throws -> Void,
            signalMonitor: OperationSignalMonitor
        ) async throws -> OperationSnapshot {
            var lastProgress: OperationProgress?
            var consecutiveFailures = 0
            while true {
                let snapshot: OperationSnapshot
                do {
                    snapshot = try await query(operationID)
                    consecutiveFailures = 0
                } catch let error as RuntimeControlClientError where isRecoverableStatusFailure(error) {
                    consecutiveFailures += 1
                    guard consecutiveFailures < maximumConsecutiveFailures else {
                        throw unknownResultError(operationID)
                    }
                    try await sleep(pollInterval)
                    continue
                }

                guard snapshot.operationID == operationID else {
                    throw unknownResultError(operationID)
                }
                if progressToStderr, let progress = snapshot.progress, progress != lastProgress {
                    let text = progressText(progress)
                    if !text.isEmpty {
                        Output.writeLogLine(
                            "Operation \(operationID.wireValue): \(text)",
                            toStandardError: true
                        )
                    }
                    lastProgress = progress
                }
                if snapshot.result != nil {
                    return snapshot
                }
                if let interruptAt = signalMonitor.firstInterruptAt,
                    Date().timeIntervalSince(interruptAt) >= 10
                {
                    throw interruptedWaitError(operationID)
                }
                try await sleep(pollInterval)
            }
        }

        static func requireSuccess(_ snapshot: OperationSnapshot) throws {
            guard let result = snapshot.result else {
                throw unknownResultError(snapshot.operationID)
            }
            switch result {
            case .succeeded(.unknown):
                throw unknownResultError(snapshot.operationID)
            case .succeeded:
                return
            case .failed(let error):
                throw error
            case .cancelled:
                throw RuntimeWireError.runtime(
                    "cancelled",
                    message: "Operation \(snapshot.operationID.wireValue) was cancelled."
                )
            case .unknown:
                throw unknownResultError(snapshot.operationID)
            }
        }

        static func installedPackage(
            from snapshot: OperationSnapshot,
            expectedPackageID: RuntimePackageID
        ) throws -> RuntimePackageSummary {
            guard snapshot.kind == .install else {
                throw unknownResultError(snapshot.operationID)
            }
            try requireSuccess(snapshot)
            guard case .succeeded(.package(let summary))? = snapshot.result,
                summary.packageID == expectedPackageID
            else {
                throw unknownResultError(snapshot.operationID)
            }
            return summary
        }

        static func checkCancelResult(_ result: CancelReply) throws {
            if case .unknown = result {
                throw RuntimeWireError.runtime(
                    "operationResultUnknown",
                    message: "APKRun couldn't determine whether the cancellation request took effect."
                )
            }
            if case .alreadyFinished(.unknown) = result {
                throw RuntimeWireError.runtime(
                    "operationResultUnknown",
                    message: "APKRun no longer knows whether the operation completed."
                )
            }
            if case .alreadyFinished(.succeeded(.unknown)) = result {
                throw RuntimeWireError.runtime(
                    "operationResultUnknown",
                    message: "APKRun no longer knows whether the operation completed."
                )
            }
            if case .alreadyFinished(.failed(let error)) = result {
                throw error
            }
        }

        static func listText(_ operations: [OperationSnapshot]) -> String {
            guard !operations.isEmpty else { return "No operations." }
            let rows = operations.map { operation in
                let packageID = operation.packageID?.rawValue ?? "-"
                let status = statusName(operation.result)
                let progress = operation.progress.map(progressText) ?? "-"
                return [
                    operation.operationID.wireValue,
                    operation.kind.rawValue,
                    packageID,
                    status,
                    progress,
                ].joined(separator: "\t")
            }
            return (["ID\tKIND\tPACKAGE\tSTATUS\tPROGRESS"] + rows).joined(separator: "\n")
        }

        static func completionText(_ snapshot: OperationSnapshot) -> String {
            guard case .succeeded(let output)? = snapshot.result else {
                return "Operation \(snapshot.operationID.wireValue) completed."
            }
            switch output {
            case .none:
                return "Operation \(snapshot.operationID.wireValue) completed."
            case .package(let summary):
                return "Installed \(DaemonInstallSupport.safeTerminalText(summary.displayName)) "
                    + "(\(summary.packageID.rawValue)), version "
                    + "\(summary.versionCode.map(String.init) ?? "unknown")."
            case .unknown:
                return "The result of operation \(snapshot.operationID.wireValue) is unknown."
            }
        }

        static func detachedText(_ snapshot: OperationSnapshot) -> String {
            "Operation \(snapshot.operationID.wireValue) is still running. "
                + "It will continue in the background; resume with "
                + "`apkrun operations wait \(snapshot.operationID.wireValue)`."
        }

        static func cancelText(_ operationID: OperationID, result: CancelReply) -> String {
            switch result {
            case .cancelling:
                "Cancellation requested for operation \(operationID.wireValue)."
            case .notCancellable(let reason):
                "Operation \(operationID.wireValue) is still running and cannot be cancelled: "
                    + DaemonInstallSupport.safeTerminalText(reason)
            case .alreadyFinished(.succeeded(.unknown)):
                "The result of operation \(operationID.wireValue) is unknown."
            case .alreadyFinished(.succeeded):
                "Operation \(operationID.wireValue) has already completed."
            case .alreadyFinished(.failed(let error)):
                "Operation \(operationID.wireValue) has already failed: "
                    + DaemonInstallSupport.safeTerminalText(error.message)
            case .alreadyFinished(.cancelled):
                "Operation \(operationID.wireValue) has already been cancelled."
            case .alreadyFinished(.unknown):
                "The result of operation \(operationID.wireValue) is unknown."
            case .unknown:
                "The result of operation \(operationID.wireValue) is unknown."
            }
        }

        static func commandFailure(_ error: any Error) async -> RuntimeWireError {
            if let wireError = error as? RuntimeWireError {
                return wireError
            }
            return await RuntimeStatusOutput.commandFailure(error)
        }

        static func writeJSON<Value: Encodable>(_ value: Value) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(OperationJSONEnvelope(result: value))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }

        private static func isRecoverableStatusFailure(_ error: RuntimeControlClientError) -> Bool {
            switch error {
            case .transportFailure, .requestTimedOut, .operationResultUnknown,
                .malformedReply, .invalidRemoteProxy:
                true
            default:
                false
            }
        }

        private static func statusName(_ result: OperationResult?) -> String {
            guard let result else { return "running" }
            switch result {
            case .succeeded: return "succeeded"
            case .failed: return "failed"
            case .cancelled: return "cancelled"
            case .unknown: return "unknown"
            }
        }

        private static func progressText(_ progress: OperationProgress) -> String {
            if let message = progress.message, !message.isEmpty {
                return DaemonInstallSupport.safeTerminalText(message)
            }
            if let stage = progress.stage, !stage.isEmpty {
                return "Stage: \(DaemonInstallSupport.safeTerminalText(stage))"
            }
            if let fraction = progress.fraction {
                let percentage = Int((min(max(fraction, 0), 1) * 100).rounded())
                return "Progress: \(percentage)%"
            }
            return ""
        }

        static func unknownResultError(_ operationID: OperationID) -> RuntimeWireError {
            RuntimeWireError.runtime(
                "operationResultUnknown",
                message: "APKRun could not confirm whether operation \(operationID.wireValue) completed.",
                remediation:
                    "Run `apkrun operations wait \(operationID.wireValue)` to check again. If the operation has expired or the daemon restarted, inspect package state before retrying."
            )
        }

        private static func interruptedWaitError(_ operationID: OperationID) -> RuntimeWireError {
            RuntimeWireError.runtime(
                "cancelled",
                message: "Stopped waiting after requesting cancellation for operation \(operationID.wireValue).",
                remediation:
                    "The operation may still be running if it passed its cancellation point. Check it with `apkrun operations wait \(operationID.wireValue)`."
            )
        }

    }

    private struct OperationJSONEnvelope<Value: Encodable>: Encodable {
        let schemaVersion = 1
        let result: Value
    }

    private struct OperationCancelEnvelope: Encodable {
        let schemaVersion = 1
        let result: Body

        init(operationID: OperationID, result: CancelReply) {
            self.result = Body(operationID: operationID, disposition: result)
        }

        struct Body: Encodable {
            let operationID: OperationID
            let disposition: CancelReply
        }
    }

    private final class OperationSignalMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private let onFirstSignal: @Sendable () -> Void
        private var signalCount = 0
        private var firstInterrupt: Date?
        private var source: DispatchSourceSignal?

        init(onFirstSignal: @escaping @Sendable () -> Void) {
            self.onFirstSignal = onFirstSignal
            _ = signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
            self.source = source
            source.setEventHandler { [weak self] in
                self?.receiveSignal()
            }
            source.resume()
        }

        var firstInterruptAt: Date? {
            lock.withLock { firstInterrupt }
        }

        private func receiveSignal() {
            let count = lock.withLock { () -> Int in
                signalCount += 1
                if signalCount == 1 {
                    firstInterrupt = Date()
                }
                return signalCount
            }
            if count == 1 {
                onFirstSignal()
            } else {
                Darwin.exit(Int32(ExitCodes.interrupted))
            }
        }

        deinit {
            source?.cancel()
            _ = signal(SIGINT, SIG_DFL)
        }
    }
#endif
