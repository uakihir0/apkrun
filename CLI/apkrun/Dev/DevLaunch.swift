#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Dispatch
    import Foundation
    import RuntimeHost

    /// `apkrun dev launch <package>`: boots Android, starts the Guest Agent, launches the package on display 0 through
    /// `LaunchApplication`, and prints the result (cli.md §5, #072). With the development window (the default, decision
    /// D13) the boot goes on until the window closes or Ctrl-C, and the window sends its pointer events to the app. With
    /// `--no-window` Android stops once the launch is done, as #072 did.
    struct DevLaunchCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "Boot Android, launch a package on display 0, and show it in a development window."
        )

        @Argument(help: "The Android package to launch, for example io.apkrun.fixture.hellotext.")
        var package: String

        @Option(
            name: .long,
            help: "The Guest Agent bundle directory (default: APKRUN_GUEST_DIR, then the app's Resources/guest).")
        var guestDir: String?

        @Flag(name: .long, help: "Launch without the window, and stop Android when the launch is done.")
        var noWindow = false

        mutating func run() async throws {
            guard isPackageName(package) else {
                throw CLIFailure.invalidArgument(argument: "package", reason: "name")
            }
            // The window is the default (decision D13). It needs the drmVirgl device, which the window's session attaches.
            let session = noWindow ? nil : DisplayWindowSession.current
            guard noWindow || session != nil else {
                throw CLIFailure.invalidArgument(argument: "--no-window", reason: "entry")
            }
            var options = DevBootOptions(
                gpu: session == nil ? .none : .virgl,
                stopWhenReady: session == nil,
                guestAgentDirectory: DevGuestAgentLocation.directory(
                    guestDir: guestDir,
                    environment: ProcessInfo.processInfo.environment,
                    executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                ),
                launchPackage: package
            )
            if let session {
                options.developerDisplay = session.display
                options.inputRoute = session.inputRoute
            }
            // With the window, the session holds the stop requests, because the window's close button makes one too.
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
            try await DevBoot().run(options: options, stopRequests: stops.stream) { event in
                switch event {
                case .state(let state):
                    Output.writeLogLine("state: \(state)", toStandardError: true)
                case .console:
                    break
                case .message(let text):
                    Output.writeLogLine(text, toStandardError: true)
                case .warning(let text):
                    Output.writeLogLine("warning: \(text)", toStandardError: true)
                case .catalogWarning(let error):
                    ErrorOutput.write(error, json: false)
                }
            }
        }

        /// Package names are dot-separated identifiers, as the device expects them.
        private func isPackageName(_ name: String) -> Bool {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count >= 2
                && parts.allSatisfy { part in
                    guard let first = part.first, first.isASCII, first.isLetter else {
                        return false
                    }
                    return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
                }
        }
    }
#endif
