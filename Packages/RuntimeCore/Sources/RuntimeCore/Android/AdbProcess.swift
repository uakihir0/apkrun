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
/// so a large `logcat -d` cannot fill a pipe and block it. A process that runs past its timeout gets
/// SIGTERM, and SIGKILL if it is still running after `terminationGrace`.
enum AdbProcess {
    /// How long a process has to exit after SIGTERM before it is killed.
    static let terminationGrace: Duration = .seconds(2)

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
                state.markExited()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            let output = Self.readToEnd(standardOutput.fileHandleForReading)
            let errorOutput = Self.readToEnd(standardError.fileHandleForReading)
            let timer = Task.detached {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, state.terminateIfRunning() else {
                    return
                }
                try? await Task.sleep(for: terminationGrace)
                state.killIfRunning()
            }
            state.attach(output: output, errorOutput: errorOutput, timer: timer)
        }
        guard let status else {
            throw .launchFailed
        }
        let (output, errorData) = await state.collect()
        if state.didTimeOut {
            throw .commandTimedOut(command: command, seconds: wholeSeconds(timeout))
        }
        return AdbProcessResult(
            status: status,
            standardOutput: String(decoding: output, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }

    /// Reads a pipe to its end on a thread of its own. A blocking read on the Swift concurrency pool
    /// holds one of the pool's few threads until the pipe closes. A command that keeps its pipes open
    /// (a sleep, or an adb server that inherited them) would then hold pool threads, and the timers that
    /// end other commands could not run, so those commands outlived their timeouts.
    private static func readToEnd(_ handle: FileHandle) -> Task<Data, Never> {
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
                Thread.detachNewThread {
                    continuation.resume(returning: handle.readDataToEndOfFile())
                }
            }
        }
    }

    /// The timeout in whole seconds, rounded up, and at least 1, so that a sub-second timeout does not read as 0.
    private static func wholeSeconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = Int(components.seconds) + (components.attoseconds > 0 ? 1 : 0)
        return max(1, seconds)
    }
}

/// The state that the termination handler, the timer, and the pipe readers share. Every change goes
/// through one lock, so the process is never signalled after it has exited.
private final class ProcessState: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private var hasExited = false
    private var timedOut = false
    private var timer: Task<Void, Never>?
    private var outputTask: Task<Data, Never>?
    private var errorTask: Task<Data, Never>?

    init(process: Process) {
        self.process = process
    }

    /// Stores the reader and timer tasks. A process that has already exited cancels the timer at once.
    func attach(output: Task<Data, Never>, errorOutput: Task<Data, Never>, timer: Task<Void, Never>) {
        lock.withLock {
            outputTask = output
            errorTask = errorOutput
            self.timer = timer
            if hasExited {
                timer.cancel()
            }
        }
    }

    func markExited() {
        lock.withLock {
            hasExited = true
            timer?.cancel()
        }
    }

    /// Sends SIGTERM when the process is still running. Returns whether it did.
    func terminateIfRunning() -> Bool {
        lock.withLock {
            guard !hasExited else {
                return false
            }
            timedOut = true
            process.terminate()
            return true
        }
    }

    /// Sends SIGKILL when the process is still running after SIGTERM.
    func killIfRunning() {
        lock.withLock {
            guard !hasExited else {
                return
            }
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    var didTimeOut: Bool {
        lock.withLock { timedOut }
    }

    /// Waits for both pipes to reach end of file, which happens when the process has exited.
    func collect() async -> (Data, Data) {
        let (output, errorOutput) = lock.withLock { (outputTask, errorTask) }
        let standardOutput = await output?.value ?? Data()
        let standardError = await errorOutput?.value ?? Data()
        return (standardOutput, standardError)
    }
}
