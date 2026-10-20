#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Dispatch
    import Foundation
    import RuntimeAPI
    import RuntimeHost

    /// `apkrun dev launch <apk|package> [apk|package]`: boots Android, starts the Guest Agent, and launches one app on
    /// the selected display or two apps in primary and secondary windows (#31). With the development window (the
    /// default, decision D13) the boot goes on until the app windows close or Ctrl-C. With `--no-window` Android stops
    /// once the one-package launch is done, as #73 did.
    struct DevLaunchCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "Boot Android, launch one or two packages, and show them in development windows."
        )

        @Argument(
            help: "A readable APK file or Android package ID. Pass two to open one app in each display window."
        )
        var packages: [String] = []

        @Option(
            name: .long,
            help: "The Guest Agent bundle directory (default: APKRUN_GUEST_DIR, then the app's Resources/guest).")
        var guestDir: String?

        @Option(
            name: .long,
            help:
                "The display for one package: 0 for compatibility or secondary for a pooled window. Two packages use primary then secondary."
        )
        var display = "0"

        @Flag(name: .long, help: "Launch one package without a window, and stop Android when the launch is done.")
        var noWindow = false

        mutating func run() async throws {
            guard (1...2).contains(packages.count) else {
                throw CLIFailure.invalidArgument(argument: "package", reason: "count")
            }
            guard display == "0" || display == "secondary" else {
                throw CLIFailure.invalidArgument(argument: "--display", reason: "name")
            }
            guard packages.count == 1 || display == "0" else {
                throw CLIFailure.invalidArgument(argument: "--display", reason: "multipleApps")
            }
            guard packages.count == 1 || !noWindow else {
                throw CLIFailure.invalidArgument(argument: "--no-window", reason: "multipleApps")
            }
            guard !noWindow || display == "0" else {
                throw CLIFailure.invalidArgument(argument: "--display", reason: "entry")
            }
            let usesSecondaryDisplay = display == "secondary"
            let session = noWindow ? nil : DisplayWindowSession.current
            guard noWindow || session != nil else {
                throw CLIFailure.invalidArgument(argument: "--no-window", reason: "entry")
            }
            let displayName = Self.displayName(for: packages[0])
            session?.publishWindowTitle(displayName)
            var additionalWindows: [DisplayWindowSession] = []
            do {
                var targets: [ResolvedTarget] = []
                for package in packages {
                    let (resolvedPackage, apkURL) = try await resolveTarget(package)
                    targets.append(ResolvedTarget(packageID: resolvedPackage, apkURL: apkURL))
                }
                guard Set(targets.map(\.packageID)).count == targets.count else {
                    throw CLIFailure.invalidArgument(argument: "package", reason: "duplicate")
                }

                var appLaunches: [DevBootAppLaunch] = []
                var packageWindows: [String: DisplayWindowSession] = [:]
                if let session {
                    packageWindows[targets[0].packageID] = session
                }
                if targets.count == 2, let session {
                    let secondarySession = session.makeAdditionalWindow()
                    additionalWindows.append(secondarySession)
                    secondarySession.publishWindowTitle(Self.displayName(for: packages[1]))
                    packageWindows[targets[1].packageID] = secondarySession
                    appLaunches = [
                        DevBootAppLaunch(
                            packageID: targets[0].packageID,
                            apkURL: targets[0].apkURL,
                            display: session.display,
                            displayMode: .primaryDisplayCompatibility,
                            inputRoute: session.inputRoute,
                            closeRequests: session.appCloseRequests.stream
                        ),
                        DevBootAppLaunch(
                            packageID: targets[1].packageID,
                            apkURL: targets[1].apkURL,
                            display: secondarySession.display,
                            displayMode: .secondaryDisplay,
                            inputRoute: secondarySession.inputRoute,
                            closeRequests: secondarySession.appCloseRequests.stream
                        ),
                    ]
                }
                // The window is the default (decision D13). It needs the drmVirgl device, which the session attaches.
                var options = DevBootOptions(
                    gpu: session == nil ? .none : .virgl,
                    stopWhenReady: session == nil,
                    guestAgentDirectory: DevGuestAgentLocation.directory(
                        guestDir: guestDir,
                        environment: ProcessInfo.processInfo.environment,
                        executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    ),
                    launchPackage: appLaunches.isEmpty ? targets[0].packageID : nil,
                    launchAPKURL: appLaunches.isEmpty ? targets[0].apkURL : nil,
                    appLaunches: appLaunches
                )
                if let session {
                    options.developerDisplay = usesSecondaryDisplay ? nil : session.display
                    options.inputRoute = appLaunches.isEmpty ? session.inputRoute : nil
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
                let eventWindows = packageWindows
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
                    appCloseRequests: appLaunches.isEmpty ? session?.appCloseRequests.stream : nil,
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
                    case .appWindowStatus(let packageID, let status):
                        eventWindows[packageID]?.publishPlaceholderStatus(status)
                    case .appWindowTitle(let packageID, let title):
                        eventWindows[packageID]?.publishWindowTitle(title)
                    case .appWindowExited(let packageID):
                        eventWindows[packageID]?.closeForAppExit()
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
                for window in additionalWindows {
                    window.closeForAppExit()
                }
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

        private struct ResolvedTarget {
            let packageID: String
            let apkURL: URL?
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
