import DiagnosticsCore
import Foundation

/// A scripted command runner for log-reader tests.
public actor FakeLogCommandRunner: LogCommandRunning {
    private var results: [LogCommandResult]
    private var argumentsHistory: [[String]] = []
    private var timeoutHistory: [Duration?] = []

    public init(results: [LogCommandResult]) {
        self.results = results
    }

    public func run(
        arguments: [String],
        initialOutputTimeout: Duration?,
        captureOutput: Bool,
        onStarted: @escaping @Sendable () -> Void,
        onReady: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> LogCommandResult {
        argumentsHistory.append(arguments)
        timeoutHistory.append(initialOutputTimeout)
        guard !results.isEmpty else {
            throw CancellationError()
        }
        let result = results.removeFirst()
        onStarted()
        if arguments.first == "stream" {
            onReady()
        }
        if !captureOutput, !result.standardOutput.isEmpty {
            onOutput(result.standardOutput)
        }
        return result
    }

    public func recordedArguments() -> [[String]] {
        argumentsHistory
    }

    public func recordedTimeouts() -> [Duration?] {
        timeoutHistory
    }
}
