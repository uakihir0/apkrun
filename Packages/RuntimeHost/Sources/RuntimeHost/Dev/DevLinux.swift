import DiagnosticsCore
import Foundation
import RuntimeCore

/// Inputs for the embedded Linux development command.
public struct DevLinuxOptions: Sendable {
    /// The uncompressed ARM64 Linux kernel image.
    public let kernelURL: URL

    /// The gzip-compressed `newc` initramfs.
    public let initrdURL: URL

    /// Checks requested from the test guest.
    public let tests: [String]

    /// Maximum seconds to wait for the guest's `done` record.
    public let timeoutSeconds: Int

    /// Creates options for one development guest run.
    public init(
        kernelURL: URL,
        initrdURL: URL,
        tests: [String] = [],
        timeoutSeconds: Int = 60
    ) {
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.tests = tests
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Events emitted while the development guest is running.
public enum DevLinuxEvent: Sendable {
    /// Raw serial output, suitable for writing directly to standard output.
    case console(Data)

    /// A parsed `APKRUN-TEST:` record.
    case record(LinuxTestGuestRecord)

    /// A lifecycle state published by the VM controller.
    case state(LinuxTestGuestState)

    /// A human-readable development warning.
    case warning(String)
}

/// Runs the minimal Linux guest inside the embedded CLI process.
public struct DevLinux: Sendable {
    private static let maximumTimeoutSeconds = 86_400

    /// Creates the development guest runner.
    public init() {}

    /// Boots the test guest, streams its output, and stops it after `done`.
    ///
    /// The instance lock is held from before VM creation through final console
    /// drain, so a second APKRun runtime cannot start during the guest run.
    public func run(
        options: DevLinuxOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onEvent: @escaping @Sendable (DevLinuxEvent) -> Void
    ) async throws {
        guard
            (1...Self.maximumTimeoutSeconds).contains(options.timeoutSeconds),
            options.tests.allSatisfy(Self.isValidTestName),
            Set(options.tests).count == options.tests.count
        else {
            throw RuntimeFailure.devLinuxInvalidOptions
        }

        let paths = APKRunPaths(allowingHomeOverride: true, environment: environment)
        let lock = try InstanceLock.acquire(paths: paths, owner: .apkrunDev)
        defer { lock.close() }

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
                initrdURL: options.initrdURL,
                tests: options.tests
            )
        )
        let eventSink = DevLinuxEventSink(onEvent)
        let consoleTask = Task {
            for await bytes in session.consoleOutput {
                guard !Task.isCancelled else { return }
                eventSink.send(.console(bytes))
            }
        }
        let stateTask = Task {
            for await state in session.states {
                guard !Task.isCancelled else { return }
                eventSink.send(.state(state))
            }
        }

        do {
            try await session.start()
            try await waitForGuest(
                session,
                requestedTests: Set(options.tests),
                timeoutSeconds: options.timeoutSeconds,
                eventSink: eventSink
            )
            try await session.stop()
            let didDrain = await session.waitForConsoleDrain()
            if !didDrain {
                consoleTask.cancel()
            }
            await consoleTask.value
            stateTask.cancel()
            await stateTask.value
        } catch {
            do {
                try await session.stop()
            } catch {
                try? await session.reset()
            }
            await session.waitForConsoleDrain()
            consoleTask.cancel()
            stateTask.cancel()
            await consoleTask.value
            await stateTask.value
            throw error
        }
    }

    private static func isValidTestName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64 else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45
                || byte == 95
        }
    }

    private func waitForGuest(
        _ session: LinuxTestGuestSession,
        requestedTests: Set<String>,
        timeoutSeconds: Int,
        eventSink: DevLinuxEventSink
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var sawBootOK = false
                var sawFailure = false
                var successfulTests: Set<String> = []

                for await record in session.records {
                    guard !Task.isCancelled else { return }
                    eventSink.send(.record(record))
                    switch record {
                    case .bootOK:
                        sawBootOK = true
                    case .check(let name, let result, _):
                        if result == .ok {
                            successfulTests.insert(name)
                        } else {
                            sawFailure = true
                        }
                    case .done:
                        guard sawBootOK else {
                            throw RuntimeFailure.devLinuxDidNotFinish
                        }
                        guard
                            !sawFailure,
                            requestedTests.isSubset(of: successfulTests)
                        else {
                            throw RuntimeFailure.devLinuxCheckFailed
                        }
                        return
                    }
                }
                throw RuntimeFailure.devLinuxDidNotFinish
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw RuntimeFailure.devLinuxTimedOut(seconds: timeoutSeconds)
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

// UNCHECKED-SENDABLE: the lock serializes all calls into the client's event handler.
private final class DevLinuxEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (DevLinuxEvent) -> Void

    init(_ handler: @escaping @Sendable (DevLinuxEvent) -> Void) {
        self.handler = handler
    }

    func send(_ event: DevLinuxEvent) {
        lock.lock()
        defer { lock.unlock() }
        handler(event)
    }
}
