#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Dispatch
    import Foundation
    import RuntimeAPI
    import RuntimeHost

    /// `apkrun dev launch <apk|package>`: boots Android, starts the Guest Agent, and launches on the selected display
    /// through `LaunchApplication`, and prints the result (cli.md §5, #072). With the development window (the default,
    /// decision D13) the boot goes on until the window closes or Ctrl-C, and the window sends its pointer events to the
    /// app. With `--no-window` Android stops once the launch is done, as #072 did.
    struct DevLaunchCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "Boot Android, launch a package on the selected display, and show it in a development window."
        )

        @Argument(
            help: "A readable APK file or Android package ID, for example HelloText.apk or io.apkrun.fixture.hellotext."
        )
        var package: String

        @Option(
            name: .long,
            help: "The Guest Agent bundle directory (default: APKRUN_GUEST_DIR, then the app's Resources/guest).")
        var guestDir: String?

        @Option(name: .long, help: "The Android display to use: 0 for compatibility, or secondary for a pooled window.")
        var display = "0"

        @Flag(name: .long, help: "Launch without the window, and stop Android when the launch is done.")
        var noWindow = false

        mutating func run() async throws {
            guard display == "0" || display == "secondary" else {
                throw CLIFailure.invalidArgument(argument: "--display", reason: "name")
            }
            guard !noWindow || display == "0" else {
                throw CLIFailure.invalidArgument(argument: "--display", reason: "entry")
            }
            let usesSecondaryDisplay = display == "secondary"
            let session = noWindow ? nil : DisplayWindowSession.current
            guard noWindow || session != nil else {
                throw CLIFailure.invalidArgument(argument: "--no-window", reason: "entry")
            }
            let displayName = Self.displayName(for: package)
            session?.publishWindowTitle(displayName)
            do {
                let (launchPackage, launchAPKURL) = try await resolveTarget(package)
                // The window is the default (decision D13). It needs the drmVirgl device, which the session attaches.
                var options = DevBootOptions(
                    gpu: session == nil ? .none : .virgl,
                    stopWhenReady: session == nil,
                    guestAgentDirectory: DevGuestAgentLocation.directory(
                        guestDir: guestDir,
                        environment: ProcessInfo.processInfo.environment,
                        executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    ),
                    launchPackage: launchPackage,
                    launchAPKURL: launchAPKURL
                )
                if let session {
                    options.developerDisplay = usesSecondaryDisplay ? nil : session.display
                    options.inputRoute = session.inputRoute
                    options.windowDisplay = session.display
                    options.windowDisplayMode =
                        usesSecondaryDisplay ? .secondaryDisplay : .primaryDisplayCompatibility
                }
                let onRuntimeReady:
                    (
                        @Sendable (DevelopmentRuntimeContext) async throws -> (
                            any RuntimeSessionService
                        )?
                    )?
                if session == nil {
                    onRuntimeReady = nil
                } else {
                    let service = EmbeddedPackageService()
                    onRuntimeReady = { context in
                        do {
                            try await service.attachRuntime(context: context)
                            return service
                        } catch {
                            Output.writeLogLine(
                                "warning: package store is unavailable; continuing with the window session",
                                toStandardError: true
                            )
                            return await context.makeSessionService()
                        }
                    }
                }
                // The session holds stop requests because its window close also sends one.
                let stops = session?.stops ?? AsyncStream.makeStream(of: Void.self)
                signal(SIGINT, SIG_IGN)
                signal(SIGTERM, SIG_IGN)
                let sources = [SIGINT, SIGTERM].map { number in
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                    source.setEventHandler { stops.continuation.yield(()) }
                    source.resume()
                    return source
                }
                defer {
                    for source in sources {
                        source.cancel()
                    }
                }
                try await DevBoot().run(
                    options: options,
                    stopRequests: stops.stream,
                    appCloseRequests: session?.appCloseRequests.stream,
                    preserveWindowOnError: session != nil,
                    onRuntimeReady: onRuntimeReady
                ) { event in
                    switch event {
                    case .state(let state):
                        Output.writeLogLine("state: \(state)", toStandardError: true)
                    case .windowStatus(let status):
                        session?.publishPlaceholderStatus(status)
                    case .windowTitle(let title):
                        session?.publishWindowTitle(title)
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
            } catch {
                if let session {
                    let failure = Self.windowFailure(for: error)
                    if await session.showFailure(
                        appName: displayName,
                        message: failure.message,
                        remediation: failure.remediation
                    ) {
                        await session.waitForAppWindowClose()
                    }
                }
                throw error
            }
        }

        private static func windowFailure(for error: any Error) -> (message: String, remediation: String) {
            let lines = ErrorOutput.render(error, json: false).components(separatedBy: .newlines)
            let message = lines.first?
                .replacingOccurrences(of: "error: ", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remediation = lines.first(where: { $0.hasPrefix("hint: ") }).map {
                String($0.dropFirst("hint: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return (
                message.flatMap { $0.isEmpty ? nil : $0 } ?? "APKRun could not start this Android app.",
                remediation.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Read the Terminal error, then run the launch command again."
            )
        }

        private static func displayName(for package: String) -> String {
            let name = URL(fileURLWithPath: package).deletingPathExtension().lastPathComponent
            return name.isEmpty ? "Android app" : name
        }

        private func resolveTarget(_ value: String) async throws -> (package: String, apkURL: URL?) {
            let inputURL = URL(fileURLWithPath: value).standardizedFileURL
            let isAPKPath = inputURL.pathExtension.lowercased() == "apk"
            guard isAPKPath else {
                guard DevelopmentAPKResolver.isValidPackageIdentifier(value) else {
                    throw CLIFailure.invalidArgument(argument: "package", reason: "name")
                }
                return (value, nil)
            }

            do {
                let resolution = try await DevelopmentAPKResolver.resolve(in: inputURL)
                if !resolution.wasSandboxed {
                    Output.writeLogLine(
                        "warning: sandbox-exec is unavailable; aapt2 is parsing the APK without sandbox restrictions",
                        toStandardError: true
                    )
                }
                return (resolution.packageIdentifier, inputURL)
            } catch let failure {
                switch failure {
                case .apkNotFound:
                    throw CLIFailure.fileNotAccessible(file: inputURL.path, .notFound)
                case .apkNotReadable:
                    throw CLIFailure.fileNotAccessible(file: inputURL.path, .permissionDenied)
                case .apkTooLarge:
                    throw CLIFailure.invalidArgument(argument: "apk", reason: "apkTooLarge")
                case .apkNotRegularFile:
                    var isDirectory: ObjCBool = false
                    _ = FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)
                    throw CLIFailure.fileNotAccessible(
                        file: inputURL.path,
                        isDirectory.boolValue ? .isDirectory : .permissionDenied
                    )
                case .aapt2NotFound:
                    throw CLIFailure.invalidArgument(argument: "apk", reason: "aapt2Missing")
                case .aapt2LaunchFailed, .apkStagingFailed, .sandboxProfileFailed:
                    throw CLIFailure.invalidArgument(argument: "apk", reason: "aapt2LaunchFailed")
                case .aapt2TimedOut:
                    throw CLIFailure.invalidArgument(argument: "apk", reason: "aapt2Timeout")
                case .aapt2OutputTooLarge:
                    throw CLIFailure.invalidArgument(argument: "apk", reason: "aapt2OutputLimit")
                case .aapt2Failed, .packageIdentifierMissing, .invalidPackageIdentifier:
                    throw CLIFailure.invalidArgument(argument: "apk", reason: "invalidAPK")
                }
            }
        }
    }
#endif
