import DiagnosticsCore
import Foundation
import RuntimeCore

/// Inputs for the embedded Linux development console.
public struct DevConsoleOptions: Sendable {
    /// The uncompressed ARM64 Linux kernel image.
    public let kernelURL: URL

    /// The gzip-compressed `newc` initramfs.
    public let initrdURL: URL

    /// Creates options for one interactive Linux guest.
    public init(kernelURL: URL, initrdURL: URL) {
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
    }
}

/// Events emitted by an interactive Linux guest session.
public enum DevConsoleEvent: Sendable {
    /// Raw serial output, suitable for writing directly to standard output.
    case console(Data)

    /// A human-readable development warning.
    case warning(String)

    /// Raw output has stopped; the count is a lower bound through the last bounded drain.
    case consoleOutputFinished(droppedBytes: UInt64)

    /// VM resources could not be released; the session retains its instance lock.
    case cleanupPending
}

/// A chunk of terminal input or an explicit Ctrl-] detach request.
public enum DevConsoleInput: Sendable {
    /// Bytes to send to the guest console.
    case bytes(Data)

    /// Stop the guest session without interpreting this as an input failure.
    case detach
}

// UNCHECKED-SENDABLE: the lock protects detachRequested; AsyncThrowingStream's continuation is thread-safe.
/// Publishes terminal input while retaining an immediate Ctrl-] control signal.
public final class DevConsoleInputChannel: @unchecked Sendable {
    /// The input events consumed by `DevConsole`.
    public let stream: AsyncThrowingStream<DevConsoleInput, any Error>

    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<DevConsoleInput, any Error>.Continuation
    private var detachRequested = false

    /// Creates an empty input channel.
    public init() {
        let input = AsyncThrowingStream<DevConsoleInput, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        stream = input.stream
        continuation = input.continuation
    }

    /// Publishes an input event, latching detach before it enters the stream.
    public func yield(_ event: DevConsoleInput) {
        if case .detach = event {
            lock.withLock {
                detachRequested = true
            }
        }
        continuation.yield(event)
    }

    /// Finishes the input stream.
    public func finish() {
        continuation.finish()
    }

    /// Finishes the input stream with a terminal read error.
    public func finish(throwing error: any Error) {
        continuation.finish(throwing: error)
    }

    /// Cancels the input producer when the console stops consuming input.
    public func onTermination(_ handler: @escaping @Sendable () -> Void) {
        continuation.onTermination = { _ in handler() }
    }

    /// Whether the producer has already published an explicit detach request.
    public var detachWasRequested: Bool {
        lock.withLock { detachRequested }
    }
}

/// Runs the minimal Linux guest and connects it to an interactive terminal.
public struct DevConsole: Sendable {
    private static let guestStopTimeout = Duration.seconds(20)

    /// Creates the development console runner.
    public init() {}

    /// Boots the Linux test guest and streams terminal input and serial output.
    ///
    /// The instance lock remains held until the guest stops and its console
    /// stream has drained, so another runtime cannot take ownership mid-session.
    public func run(
        options: DevConsoleOptions,
        input: DevConsoleInputChannel,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onOutputStop: @escaping @Sendable () -> Void = {},
        onEvent: @escaping @Sendable (DevConsoleEvent) -> Void
    ) async throws {
        let paths = APKRunPaths(allowingHomeOverride: true, environment: environment)
        let instanceLock = try InstanceLock.acquire(paths: paths, owner: .apkrunDev)
        defer { instanceLock.close() }

        let defaultPaths = APKRunPaths(allowingHomeOverride: true, environment: [:])
        if paths.dataRoot.standardizedFileURL != defaultPaths.dataRoot.standardizedFileURL {
            onEvent(
                .warning(
                    "APKRUN_HOME selects a separate data root. Running this guest may increase memory use."
                )
            )
        }

        let diagnostics = DiagnosticsContext.live(paths: paths)
        let runner = LinuxTestGuestRunner(diagnostics: diagnostics)
        let session = try runner.makeSession(
            options: LinuxTestGuestOptions(
                kernelURL: options.kernelURL,
                initrdURL: options.initrdURL
            )
        )
        let eventSink = DevConsoleEventSink(onEvent)
        let signals = AsyncStream.makeStream(
            of: DevConsoleSignal.self,
            bufferingPolicy: .unbounded
        )
        let inputWriter = DevConsoleInputWriter(
            write: { [session] bytes in
                try session.writeConsoleInput(bytes)
            },
            onFailure: {
                signals.continuation.yield(.inputFailed)
            }
        )
        let consoleTask = Task {
            for await bytes in session.consoleOutput {
                guard !Task.isCancelled else { break }
                guard !bytes.isEmpty else {
                    session.acknowledgeConsoleOutputBarrier()
                    continue
                }
                eventSink.send(.console(bytes))
                session.acknowledgeConsoleOutput(bytes.count)
            }
            session.acknowledgeConsoleOutputStreamEnd()
        }
        let stateTask = Task {
            for await state in session.states {
                guard !Task.isCancelled else { return }
                signals.continuation.yield(.state(state))
            }
        }
        let inputTask = Task {
            var inputOverflowed = false
            do {
                for try await event in input.stream {
                    guard !Task.isCancelled else { return }
                    switch event {
                    case .bytes(let bytes):
                        guard !inputOverflowed else { continue }
                        if !inputWriter.enqueue(bytes) {
                            inputOverflowed = true
                            signals.continuation.yield(.inputOverflowed)
                        }
                    case .detach:
                        signals.continuation.yield(.detachRequested)
                        return
                    }
                }
                signals.continuation.yield(.inputEnded)
            } catch {
                signals.continuation.yield(.inputFailed)
            }
        }

        var stopTimeoutTask: Task<Void, Never>?
        do {
            try await session.start()
            var sawRunning = false
            var requestedGuestStop = false
            var inputOverflowed = false
            var completed = false

            func requestGuestStop() async throws {
                guard !requestedGuestStop else { return }
                inputWriter.cancel()
                requestedGuestStop = true
                try await session.requestGuestStop()
                stopTimeoutTask = Task {
                    do {
                        try await Task.sleep(for: Self.guestStopTimeout)
                    } catch {
                        return
                    }
                    signals.continuation.yield(.stopDeadline)
                }
            }

            for await signal in signals.stream {
                switch signal {
                case .inputEnded:
                    guard !requestedGuestStop else { continue }
                    if inputOverflowed {
                        throw RuntimeFailure.devConsoleInputFailed
                    }
                    try await requestGuestStop()
                case .detachRequested:
                    try await requestGuestStop()
                case .inputOverflowed:
                    inputOverflowed = true
                case .inputFailed:
                    guard !requestedGuestStop else { continue }
                    guard input.detachWasRequested else {
                        throw RuntimeFailure.devConsoleInputFailed
                    }
                    try await requestGuestStop()
                case .state(.running):
                    sawRunning = true
                case .state(.stopped) where sawRunning:
                    completed = true
                case .state(.failed):
                    throw RuntimeFailure.devConsoleGuestFailed
                case .state:
                    continue
                case .stopDeadline:
                    try await session.stop()
                    completed = true
                }

                if completed {
                    break
                }
            }
            stopTimeoutTask?.cancel()
            inputWriter.cancel()
            inputTask.cancel()
            stateTask.cancel()
            if !completed {
                try await session.stop()
            }
            let didDrain = await session.waitForConsoleDrain()
            if !didDrain {
                onOutputStop()
                await session.waitForConsoleOutputDrain()
                consoleTask.cancel()
            }
            await consoleTask.value
            eventSink.send(
                .consoleOutputFinished(
                    droppedBytes: session.consoleOutputLossByteCount
                )
            )
            await inputWriter.waitForCompletion()
        } catch {
            stopTimeoutTask?.cancel()
            inputWriter.cancel()
            inputTask.cancel()
            stateTask.cancel()
            var didReleaseVM = false
            do {
                try await session.stop()
                didReleaseVM = true
            } catch {
                do {
                    try await session.reset()
                    didReleaseVM = true
                } catch {}
            }
            if !didReleaseVM {
                onOutputStop()
                await session.waitForConsoleOutputDrain()
                consoleTask.cancel()
                await consoleTask.value
                eventSink.send(.cleanupPending)
                eventSink.send(
                    .consoleOutputFinished(droppedBytes: session.consoleOutputLossByteCount)
                )
                await session.waitForConsoleDrain()
                await inputWriter.waitForCompletion()
            } else {
                let didDrain = await session.waitForConsoleDrain()
                if !didDrain {
                    onOutputStop()
                    await session.waitForConsoleOutputDrain()
                    consoleTask.cancel()
                }
                await consoleTask.value
                await inputWriter.waitForCompletion()
                eventSink.send(
                    .consoleOutputFinished(
                        droppedBytes: session.consoleOutputLossByteCount
                    )
                )
            }
            throw error
        }
    }
}

private enum DevConsoleSignal: Sendable {
    case inputEnded
    case detachRequested
    case inputOverflowed
    case inputFailed
    case state(LinuxTestGuestState)
    case stopDeadline
}

// UNCHECKED-SENDABLE: the lock serializes all calls into the client's event handler.
private final class DevConsoleEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (DevConsoleEvent) -> Void

    init(_ handler: @escaping @Sendable (DevConsoleEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: DevConsoleEvent) {
        lock.lock()
        defer { lock.unlock() }
        handler(event)
    }
}
