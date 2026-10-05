import DiagnosticsCore
import Foundation
import VirtualMachineCore

/// Inputs for one small Linux development guest.
public struct LinuxTestGuestOptions: Sendable {
    /// The uncompressed ARM64 Linux `Image`.
    public let kernelURL: URL

    /// The gzip-compressed `newc` initramfs.
    public let initrdURL: URL

    /// Test names requested from the guest init script.
    public let tests: [String]

    /// Whether the guest powers itself off after printing its done marker.
    public let powerOff: Bool

    /// Additional fixed kernel command-line arguments.
    public let extraCommandLine: [String]

    /// Creates options for the test guest.
    public init(
        kernelURL: URL,
        initrdURL: URL,
        tests: [String] = [],
        powerOff: Bool = false,
        extraCommandLine: [String] = []
    ) {
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.tests = tests
        self.powerOff = powerOff
        self.extraCommandLine = extraCommandLine
    }
}

/// Creates validated test-guest sessions using VirtualMachineCore.
public struct LinuxTestGuestRunner: Sendable {
    private let diagnostics: DiagnosticsContext

    /// Creates a runner with the process's diagnostics dependencies.
    public init(diagnostics: DiagnosticsContext) {
        self.diagnostics = diagnostics
    }

    /// Validates the guest definition and starts parsing its system console.
    public func makeSession(
        options: LinuxTestGuestOptions
    ) throws -> LinuxTestGuestSession {
        let definition = LinuxTestGuest.definition(
            kernel: options.kernelURL,
            initrd: options.initrdURL,
            tests: options.tests,
            powerOff: options.powerOff,
            extraCommandLine: options.extraCommandLine
        )
        let validated = try VMDefinitionValidator().validate(definition)
        let controller = VMController(
            definition: validated,
            diagnostics: diagnostics
        )
        return LinuxTestGuestSession(controller: controller)
    }
}

/// Lifecycle states of one Linux test guest.
public enum LinuxTestGuestState: String, Equatable, Sendable {
    /// The VM has no active guest.
    case stopped

    /// Virtualization.framework is starting the VM.
    case starting

    /// The guest is running.
    case running

    /// The guest VM is paused.
    case paused

    /// The guest is stopping.
    case stopping

    /// The VM lifecycle failed.
    case failed
}

/// A parsed test result emitted by the Linux guest.
public enum LinuxTestGuestRecord: Equatable, Sendable {
    /// The guest reached userspace.
    case bootOK

    /// A named guest check completed.
    case check(name: String, result: LinuxTestGuestCheckResult, detail: String)

    /// The guest finished its requested checks.
    case done
}

/// The result value reported by one Linux guest check.
public enum LinuxTestGuestCheckResult: String, Equatable, Sendable {
    /// The guest reports success.
    case ok

    /// The guest reports failure.
    case fail
}

/// One Linux VM and streams for its console, state changes, and parsed records.
public final class LinuxTestGuestSession: Sendable {
    /// The raw serial output, with the same bounded buffering as `ConsoleChannel`.
    public let consoleOutput: AsyncStream<Data>

    /// The number of bytes dropped from the bounded raw console output stream.
    public var consoleOutputDroppedByteCount: UInt64 {
        consoleOutputByteStream.droppedByteCount
    }

    package var consoleOutputLossByteCount: UInt64 {
        consoleOutputByteStream.droppedAndPendingByteCount
    }

    /// Parsed `APKRUN-TEST:` records, including the boot and done markers.
    public let records: AsyncStream<LinuxTestGuestRecord>

    /// VM lifecycle changes, including the initial `.stopped` state.
    public let states: AsyncStream<LinuxTestGuestState>

    private let controller: VMController
    private let consoleOutputByteStream: ConsoleByteStream
    private let recordTask: Task<Void, Never>
    private let stateTask: Task<Void, Never>

    fileprivate init(controller: VMController) {
        self.controller = controller
        let console = controller.console(.systemConsole)
        let recordByteStream = console.makeByteStream()
        let recordStream = AsyncStream.makeStream(
            of: LinuxTestGuestRecord.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        records = recordStream.stream
        recordTask = Task {
            var parser = TestGuestLineParser()
            for await bytes in recordByteStream.stream {
                guard !Task.isCancelled else { break }
                for record in parser.consume(bytes) {
                    recordStream.continuation.yield(Self.map(record))
                }
                recordByteStream.acknowledgeConsumedBytes(bytes.count)
            }
            if !Task.isCancelled {
                for record in parser.finish() {
                    recordStream.continuation.yield(Self.map(record))
                }
            }
            recordStream.continuation.finish()
        }
        let consoleOutputByteStream = console.makeByteStream()
        self.consoleOutputByteStream = consoleOutputByteStream
        consoleOutput = consoleOutputByteStream.stream

        let stateStream = AsyncStream.makeStream(
            of: LinuxTestGuestState.self,
            bufferingPolicy: .unbounded
        )
        states = stateStream.stream
        let stateUpdates = controller.stateUpdates
        stateTask = Task {
            for await state in stateUpdates {
                stateStream.continuation.yield(Self.map(state))
            }
            stateStream.continuation.finish()
        }
    }

    /// Starts the guest.
    public func start() async throws {
        try await controller.start()
    }

    /// Sends a power-button request to the guest.
    public func requestGuestStop() async throws {
        try await controller.requestGuestStop()
    }

    /// Sends host input to the guest's system console.
    public func writeConsoleInput(_ data: Data) throws(ConsoleChannelWriteFailure) {
        try controller.console(.systemConsole).writeHostInput(data)
    }

    package func acknowledgeConsoleOutput(_ byteCount: Int) {
        consoleOutputByteStream.acknowledgeConsumedBytes(byteCount)
    }

    package func acknowledgeConsoleOutputBarrier() {
        consoleOutputByteStream.acknowledgeDrainBarrier()
    }

    package func acknowledgeConsoleOutputStreamEnd() {
        consoleOutputByteStream.acknowledgeStreamEnd()
    }

    package func waitForConsoleOutputDrain() async {
        await consoleOutputByteStream.waitForDrain()
    }

    /// Force-stops the guest.
    public func stop() async throws {
        try await controller.stop()
    }

    /// Clears a failed VM state after releasing its framework objects.
    public func reset() async throws {
        try await controller.reset()
    }

    /// Waits for the VM log sync and up to two seconds for parsed console EOF.
    ///
    /// Returns `false` when the stream did not reach EOF within the timeout.
    @discardableResult
    public func waitForConsoleDrain() async -> Bool {
        let didDrain = await waitForConsoleTaskDrain(recordTask, timeout: .seconds(2))
        await controller.waitForConsoleLogDrain()
        return didDrain
    }

    deinit {
        recordTask.cancel()
        stateTask.cancel()
    }

    private static func map(_ record: TestGuestRecord) -> LinuxTestGuestRecord {
        switch record {
        case .bootOK:
            .bootOK
        case .check(let name, let result, let detail):
            .check(
                name: name,
                result: result == .ok ? .ok : .fail,
                detail: detail
            )
        case .done:
            .done
        }
    }

    private static func map(_ state: VMState) -> LinuxTestGuestState {
        switch state {
        case .stopped: .stopped
        case .starting: .starting
        case .running: .running
        case .paused: .paused
        case .stopping: .stopping
        case .failed: .failed
        }
    }
}

package func waitForConsoleTaskDrain(
    _ task: Task<Void, Never>,
    timeout: Duration
) async -> Bool {
    let didDrain = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await task.value
            return true
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }

        let didDrain = await group.next() ?? false
        if !didDrain {
            task.cancel()
        }
        group.cancelAll()
        return didDrain
    }
    if !didDrain {
        task.cancel()
    }
    await task.value
    return didDrain
}
