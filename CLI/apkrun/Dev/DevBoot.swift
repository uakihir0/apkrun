#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Dispatch
    import Foundation
    import RuntimeAPI
    import RuntimeHost
    import WindowingCore

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

        @Option(name: .long, help: "Loopback TCP port for developer ADB (0 lets the system choose).")
        var adbHostPort = DevBootOptions.defaultADBHostPort

        @Flag(name: .long, help: "Provision a fresh Android instance first (Reset Android).")
        var reset = false

        @Flag(name: .long, help: "Stop Android as soon as it is ready.")
        var stopWhenReady = false

        @Flag(name: .long, help: "Copy the kernel console (hvc0) to standard output.")
        var console = false

        @Flag(
            name: .long,
            help: "Show display 0 in a development window. Needs `--gpu virgl`. Closing it stops Android."
        )
        var window = false

        @Flag(name: .long, help: "Show the frame rate and the pixel counters in the window, and log them every second.")
        var stats = false

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
            // The window shows the scanout of the drmVirgl device, and the other profiles have no presenter (#24).
            guard !window || profile == .virgl else {
                throw CLIFailure.invalidArgument(argument: "--window", reason: "profile")
            }
            let gibibyte: UInt64 = 1024 * 1024 * 1024
            var options = DevBootOptions(
                gpu: profile,
                adbHostPort: adbHostPort,
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

            // With `--window`, the session holds the stop requests, because the window's close button makes one too.
            let session = window ? DisplayWindowSession.current : nil
            guard !window || session != nil else {
                throw CLIFailure.invalidArgument(argument: "--window", reason: "entry")
            }
            let stops = session?.stops ?? AsyncStream.makeStream(of: Void.self)
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
            let onEvent: @Sendable (DevBootEvent) -> Void = { event in
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
                case .catalogWarning(let error):
                    ErrorOutput.write(error, json: false)
                case .windowStatus, .windowTitle, .appWindowStatus, .appWindowTitle, .appWindowExited:
                    break
                }
            }

            if let session {
                // The window's session runs the boot here. The event loop is on the main thread, and it ends with the command.
                options.developerDisplay = session.display
                options.inputRoute = session.inputRoute
            }
            let packageService = EmbeddedPackageService()
            try await DevBoot().run(
                options: options,
                stopRequests: stops.stream,
                onRuntimeReady: { context in
                    guard await context.supervisor.developmentGuestAgent != nil else {
                        return nil
                    }
                    do {
                        try await packageService.attachRuntime(context: context)
                        return packageService
                    } catch let error as RuntimeWireError {
                        onEvent(.warning("package inventory refresh failed (\(error.code)); continuing Android boot"))
                        return nil
                    } catch {
                        onEvent(.warning("package inventory refresh failed; continuing Android boot"))
                        return nil
                    }
                },
                onEvent: onEvent
            )
        }
    }
#endif
