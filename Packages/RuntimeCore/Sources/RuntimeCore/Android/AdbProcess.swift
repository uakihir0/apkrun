import Foundation

/// The result of one `adb` process.
struct AdbProcessResult: Equatable, Sendable {
    /// The exit status.
    var status: Int32
    /// Standard output, decoded as UTF-8.
    var standardOutput: String
    /// Standard error, decoded as UTF-8.
    var standardError: String
}

/// Runs one `adb` process with a timeout (#015). Both output pipes are drained while the process runs,
/// so a large `logcat -d` cannot fill a pipe and block it.
enum AdbProcess {
    /// Runs `executable` with `arguments`, terminating it when `timeout` expires.
    static func run(
        executable: URL,
        arguments: [String],
        command: String,
        timeout: Duration
    ) async throws(AdbFailure) -> AdbProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        let state = ProcessState(process: process)

        let status: Int32? = await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            process.terminationHandler = { finished in
                state.timer?.cancel()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            state.outputTask = Task.detached {
                standardOutput.fileHandleForReading.readDataToEndOfFile()
            }
            state.errorTask = Task.detached {
                standardError.fileHandleForReading.readDataToEndOfFile()
            }
            state.timer = Task.detached {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, state.process.isRunning else {
                    return
                }
                state.markTimedOut()
                state.process.terminate()
            }
        }
        guard let status else {
            throw .launchFailed
        }
        let output = await state.outputTask?.value ?? Data()
        let errorOutput = await state.errorTask?.value ?? Data()
        if state.didTimeOut {
            throw .commandTimedOut(command: command, seconds: Self.wholeSeconds(timeout))
        }
        return AdbProcessResult(
            status: status,
            standardOutput: String(decoding: output, as: UTF8.self),
            standardError: String(decoding: errorOutput, as: UTF8.self)
        )
    }

    private static func wholeSeconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }
}

/// The state that the termination handler, the timer, and the pipe readers share.
private final class ProcessState: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var timedOut = false
    var timer: Task<Void, Never>?
    var outputTask: Task<Data, Never>?
    var errorTask: Task<Data, Never>?

    init(process: Process) {
        self.process = process
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }
}
