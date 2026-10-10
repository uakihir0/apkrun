#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Dispatch
    import Foundation
    import RuntimeHost

    struct DevBootCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "boot",
            abstract: "Boot Android from the current development image."
        )

        @Option(
            name: .long,
            help: "GPU profile: `none` (headless, the default), `swiftshader` (guest software rendering), or `virgl`."
        )
        var gpu = DevGPUProfile.none.rawValue

        @Flag(name: .long, help: "Provision a fresh Android instance first (Reset Android).")
        var reset = false

        @Flag(name: .long, help: "Stop Android as soon as it is ready.")
        var stopWhenReady = false

        @Flag(name: .long, help: "Copy the kernel console (hvc0) to standard output.")
        var console = false

        @Option(name: .long, help: "Guest vCPUs for a new instance (1-16).")
        var cpus = 4

        @Option(name: .long, help: "Guest memory in GiB for a new instance (2-32).")
        var memoryGib = 4

        @Option(name: .long, help: "Logical userdata size in GiB for a new instance (8-256).")
        var userdataGib = 32

        @Option(
            name: .long,
            help: "The Guest Agent bundle directory (default: APKRUN_GUEST_DIR, then the app's Resources/guest).")
        var guestDir: String?

        mutating func run() async throws {
            guard let profile = DevGPUProfile(rawValue: gpu) else {
                throw CLIFailure.invalidArgument(argument: "--gpu", reason: "profile")
            }
            guard (1...16).contains(cpus) else {
                throw CLIFailure.invalidArgument(argument: "--cpus", reason: "range")
            }
            guard (2...32).contains(memoryGib) else {
                throw CLIFailure.invalidArgument(argument: "--memory-gib", reason: "range")
            }
            guard (8...256).contains(userdataGib) else {
                throw CLIFailure.invalidArgument(argument: "--userdata-gib", reason: "range")
            }
            let gibibyte: UInt64 = 1024 * 1024 * 1024
            let options = DevBootOptions(
                gpu: profile,
                cpuCount: cpus,
                memoryBytes: UInt64(memoryGib) * gibibyte,
                userdataBytes: UInt64(userdataGib) * gibibyte,
                resetInstance: reset,
                stopWhenReady: stopWhenReady,
                guestAgentDirectory: DevGuestAgentLocation.directory(
                    guestDir: guestDir,
                    environment: ProcessInfo.processInfo.environment,
                    executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                )
            )

            let stops = AsyncStream.makeStream(of: Void.self)
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let sources = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { stops.continuation.yield() }
                source.resume()
                return source
            }
            defer {
                for source in sources {
                    source.cancel()
                }
            }

            let copyConsole = console
            try await DevBoot().run(options: options, stopRequests: stops.stream) { event in
                switch event {
                case .state(let state):
                    Output.writeLogLine("state: \(state)", toStandardError: true)
                case .console(let bytes):
                    if copyConsole {
                        FileHandle.standardOutput.write(bytes)
                    }
                case .message(let text):
                    Output.writeLogLine(text, toStandardError: true)
                case .warning(let text):
                    Output.writeLogLine("warning: \(text)", toStandardError: true)
                }
            }
        }
    }
#endif
