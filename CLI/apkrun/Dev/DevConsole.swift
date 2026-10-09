#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Darwin
    import DiagnosticsCore
    import Foundation
    import RuntimeHost

    struct DevConsoleCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "console",
            abstract: "Boot Linux and connect the terminal to its serial console."
        )

        @Option(name: .long, help: "Path to the uncompressed ARM64 Linux kernel.")
        var kernel: String?

        @Option(name: .long, help: "Path to the gzip-compressed initramfs.")
        var initrd: String?

        @Flag(name: .long, help: "Attach to the Android serial shell (hvc1) of a running `apkrun dev boot`.")
        var androidShell = false

        mutating func run() async throws {
            if androidShell {
                try await attachAndroidShell()
                return
            }
            #if DEBUG
                let override = ProcessInfo.processInfo.environment["APKRUN_TEST_LINUX_DIR"]
            #else
                let override: String? = nil
            #endif
            let artifactDirectory: URL
            if let override, !override.isEmpty {
                guard override.hasPrefix("/") else {
                    throw RuntimeFailure.devLinuxArtifactDirectoryMustBeAbsolute
                }
                artifactDirectory =
                    URL(fileURLWithPath: override, isDirectory: true)
                    .standardizedFileURL
            } else {
                artifactDirectory = URL(
                    fileURLWithPath: "/tmp/apkrun-test-linux",
                    isDirectory: true
                )
            }

            let terminalRestore = TerminalRestoreController(try RawConsoleTerminal())
            defer { terminalRestore.restore() }
            let outputWriter: DevConsoleOutputWriter
            do {
                outputWriter = try DevConsoleOutputWriter(fileDescriptor: STDOUT_FILENO)
            } catch {
                throw CLIFailure.devConsoleRequiresTerminal
            }
            defer { outputWriter.restore() }
            let inputPump = TerminalConsoleInputPump(fileDescriptor: STDIN_FILENO)
            defer { inputPump.cancel() }

            do {
                try await DevConsole().run(
                    options: DevConsoleOptions(
                        kernelURL: kernel.map { URL(fileURLWithPath: $0) }
                            ?? artifactDirectory.appendingPathComponent("Image"),
                        initrdURL: initrd.map { URL(fileURLWithPath: $0) }
                            ?? artifactDirectory.appendingPathComponent("initramfs.cpio.gz")
                    ),
                    input: inputPump.input,
                    onOutputStop: {
                        outputWriter.cancelPendingWrites()
                        outputWriter.restore()
                        terminalRestore.restore()
                    },
                    onEvent: { event in
                        switch event {
                        case .console(let data):
                            outputWriter.write(data)
                        case .warning(let message):
                            Output.writeLogLine("warning: \(message)", toStandardError: true)
                        case .consoleOutputFinished(let droppedBytes):
                            outputWriter.restore()
                            terminalRestore.restore()
                            let totalDroppedBytes = droppedBytes &+ outputWriter.droppedByteCount
                            if totalDroppedBytes > 0 {
                                ErrorOutput.write(
                                    RuntimeFailure.devConsoleOutputDropped(bytes: totalDroppedBytes),
                                    json: false
                                )
                            }
                        case .cleanupPending:
                            ErrorOutput.write(RuntimeFailure.devConsoleCleanupPending, json: false)
                        }
                    }
                )
            } catch {
                inputPump.cancel()
                await inputPump.task.value
                throw error
            }
            inputPump.cancel()
            await inputPump.task.value
        }
    }

    /// Relays this terminal to the Android serial shell socket of a running `apkrun dev boot` (#014).
    ///
    /// The socket is the owner's; this command only attaches. Ctrl-] detaches.
    private func attachAndroidShell() async throws {
        let paths = APKRunPaths(allowingHomeOverride: true, environment: ProcessInfo.processInfo.environment)
        let descriptor = try DevConsoleSocketClient.connect(console: "hvc1", directory: paths.devConsoleDirectory)
        defer { Darwin.close(descriptor) }

        let terminalRestore = TerminalRestoreController(try RawConsoleTerminal())
        defer { terminalRestore.restore() }
        let outputWriter: DevConsoleOutputWriter
        do {
            outputWriter = try DevConsoleOutputWriter(fileDescriptor: STDOUT_FILENO)
        } catch {
            throw CLIFailure.devConsoleRequiresTerminal
        }
        defer { outputWriter.restore() }
        let inputPump = TerminalConsoleInputPump(fileDescriptor: STDIN_FILENO)
        defer { inputPump.cancel() }

        let reader = Task.detached(priority: .userInitiated) {
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while !Task.isCancelled {
                let count = read(descriptor, &buffer, buffer.count)
                if count <= 0 {
                    break
                }
                outputWriter.write(Data(buffer.prefix(count)))
            }
            terminalRestore.restore()
        }
        defer { reader.cancel() }

        for try await input in inputPump.input.stream {
            switch input {
            case .bytes(let data):
                try data.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    var offset = 0
                    while offset < raw.count {
                        let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                        if written <= 0 {
                            throw RuntimeFailure.devConsoleInputFailed
                        }
                        offset += written
                    }
                }
            case .detach:
                return
            }
        }
    }

    private struct RawConsoleTerminal {
        private let fileDescriptor: Int32
        private let originalSettings: termios

        init() throws {
            guard
                isatty(STDIN_FILENO) == 1,
                isatty(STDOUT_FILENO) == 1
            else {
                throw CLIFailure.devConsoleRequiresTerminal
            }

            var settings = termios()
            guard tcgetattr(STDIN_FILENO, &settings) == 0 else {
                throw CLIFailure.devConsoleRequiresTerminal
            }
            originalSettings = settings
            fileDescriptor = STDIN_FILENO
            cfmakeraw(&settings)
            guard tcsetattr(fileDescriptor, TCSANOW, &settings) == 0 else {
                throw CLIFailure.devConsoleRequiresTerminal
            }
        }

        func restore() {
            var settings = originalSettings
            _ = tcsetattr(fileDescriptor, TCSANOW, &settings)
        }
    }

    // UNCHECKED-SENDABLE: the lock protects one-time restoration; terminal settings are immutable.
    private final class TerminalRestoreController: @unchecked Sendable {
        private let lock = NSLock()
        private let terminal: RawConsoleTerminal
        private var isRestored = false

        init(_ terminal: RawConsoleTerminal) {
            self.terminal = terminal
        }

        func restore() {
            lock.lock()
            guard !isRestored else {
                lock.unlock()
                return
            }
            isRestored = true
            lock.unlock()
            terminal.restore()
        }
    }

    private struct TerminalConsoleInputPump: Sendable {
        let input: DevConsoleInputChannel
        let task: Task<Void, Never>

        init(fileDescriptor: Int32) {
            let input = DevConsoleInputChannel()
            self.input = input
            let inputTask = Task.detached(priority: .userInitiated) {
                var buffer = [UInt8](repeating: 0, count: 4_096)
                defer { input.finish() }

                while !Task.isCancelled {
                    var descriptor = pollfd(
                        fd: fileDescriptor,
                        events: Int16(POLLIN | POLLHUP),
                        revents: 0
                    )
                    let readiness = Darwin.poll(&descriptor, 1, 100)
                    if readiness < 0 {
                        if errno == EINTR { continue }
                        input.finish(throwing: TerminalConsoleInputFailure.poll(errno))
                        return
                    }
                    guard readiness > 0 else { continue }

                    let byteCount = buffer.withUnsafeMutableBytes { rawBuffer in
                        Darwin.read(
                            fileDescriptor,
                            rawBuffer.baseAddress,
                            rawBuffer.count
                        )
                    }
                    if byteCount < 0 {
                        if errno == EINTR { continue }
                        input.finish(throwing: TerminalConsoleInputFailure.read(errno))
                        return
                    }
                    guard byteCount > 0 else { return }

                    let chunk = Data(buffer.prefix(byteCount))
                    if let detachIndex = chunk.firstIndex(of: 0x1D) {
                        let guestInput = Data(chunk[..<detachIndex])
                        if !guestInput.isEmpty {
                            input.yield(.bytes(guestInput))
                        }
                        input.yield(.detach)
                        return
                    }
                    input.yield(.bytes(chunk))
                }
            }
            task = inputTask
            input.onTermination {
                inputTask.cancel()
            }
        }

        func cancel() {
            task.cancel()
        }
    }

    private enum TerminalConsoleInputFailure: Error, Sendable {
        case poll(Int32)
        case read(Int32)
    }
#endif
