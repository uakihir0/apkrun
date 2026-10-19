#if APKRUN_EMBEDDED_RUNTIME
    import AppKit
    import Foundation
    import RuntimeHost
    import WindowingCore

    private enum DisplayWindowUpdate: Sendable {
        case title(String)
        case status(String)
    }

    /// The window of `apkrun dev boot --window`: the display, the stop requests, and the event loop (#023).
    ///
    /// AppKit runs on the main thread, so `APKRunCommand.main` enters the loop there before its first suspension, and the
    /// command runs on a detached task. The window's close button stops the boot, and the end of the boot ends the loop.
    final class DisplayWindowSession: @unchecked Sendable {
        /// The session of this process, which only `dev boot --window` makes.
        // UNCHECKED-SENDABLE: written once before the command starts, and read under the lock.
        private static let registryLock = NSLock()
        nonisolated(unsafe) private static var registered: DisplayWindowSession?

        /// The session of this process, or `nil` for every other command.
        static var current: DisplayWindowSession? {
            registryLock.withLock { registered }
        }

        enum Request: Equatable {
            case boot
            case launch
        }

        /// The requested development window, based on the actual command path.
        ///
        /// `dev boot --window` opens a boot window; `dev launch` opens an app window unless it has `--no-window`
        /// (decision D13). A request for help does not open a window. Command arguments are inspected before
        /// `--` so positional values cannot change the selected command or window mode.
        static func request(in arguments: [String]) -> Request? {
            let commandArguments = Array(arguments.prefix(while: { $0 != "--" }))
            let helpRequested =
                commandArguments.first == "help"
                || commandArguments.contains { ["-h", "-help", "--help"].contains($0) }
            guard !helpRequested else {
                return nil
            }
            guard commandArguments.count >= 2, commandArguments[0] == "dev" else {
                return nil
            }
            switch commandArguments[1] {
            case "boot" where commandArguments.contains("--window"):
                return .boot
            case "launch" where !commandArguments.contains("--no-window"):
                return .launch
            default:
                return nil
            }
        }

        /// Display 0 resolved from the default portrait size, visible frame, and main screen's backing scale.
        let display: DeveloperDisplay
        /// Stop requests for the boot: Ctrl-C, or the window closing.
        let stops = AsyncStream.makeStream(of: Void.self)
        /// App-session close requests, separate from Ctrl-C so dev launch can finish tasks before VM shutdown.
        let appCloseRequests = AsyncStream.makeStream(of: Void.self)
        private let windowUpdates: AsyncStream<DisplayWindowUpdate>
        private let windowUpdateContinuation: AsyncStream<DisplayWindowUpdate>.Continuation
        /// The development input route of the boot. The boot binds it to display 0 (#024).
        let inputRoute: DevInputRoute
        /// The window's pointer events, sent to `inputRoute`.
        let inputSink: EmbeddedInputSink
        /// Whether the statistics go to standard error as well as to the window title.
        let showStatistics: Bool
        private let stopsAppOnClose: Bool
        private var pump: DisplayPump?
        private var windowUpdateTask: Task<Void, Never>?
        @MainActor private var earlyFailureWindow: SessionFailureWindowController?

        private init(
            showStatistics: Bool,
            stopsAppOnClose: Bool,
            backingScale: CGFloat,
            pointSize: CGSize
        ) {
            self.showStatistics = showStatistics
            self.stopsAppOnClose = stopsAppOnClose
            let (windowUpdates, windowUpdateContinuation) = AsyncStream.makeStream(
                of: DisplayWindowUpdate.self,
                bufferingPolicy: .bufferingNewest(16)
            )
            self.windowUpdates = windowUpdates
            self.windowUpdateContinuation = windowUpdateContinuation
            do {
                display = try DeveloperDisplay(
                    pointSize: pointSize,
                    backingScale: backingScale
                )
            } catch {
                Output.writeLogLine(
                    "warning: the initial display geometry could not be resolved; using the clamped size at 160 dpi",
                    toStandardError: true
                )
                display = DeveloperDisplay(
                    pixelWidth: max(2, Int(pointSize.width.rounded())),
                    pixelHeight: max(2, Int(pointSize.height.rounded()))
                )
            }
            let route = DevInputRoute()
            inputRoute = route
            inputSink = EmbeddedInputSink(route: route)
        }

        /// Runs `command` on a detached task, and the window's event loop on this thread, until the command ends.
        ///
        /// Call it on the main thread, from a context that is not an actor job: nothing is awaited before the loop starts.
        static func runEventLoop(
            showStatistics: Bool,
            stopsAppOnClose: Bool = false,
            command: @escaping @Sendable () async -> Void
        ) {
            let geometry = MainActor.assumeIsolated {
                let screen = NSScreen.main
                let visibleSize =
                    screen?.visibleFrame.size
                    ?? CGSize(width: 480 / 0.9, height: 850 / 0.9)
                let pointSize = CGSize(
                    width: min(480, visibleSize.width * 0.9),
                    height: min(850, visibleSize.height * 0.9)
                )
                return (pointSize, screen?.backingScaleFactor ?? 1)
            }
            let session = DisplayWindowSession(
                showStatistics: showStatistics,
                stopsAppOnClose: stopsAppOnClose,
                backingScale: geometry.1,
                pointSize: geometry.0
            )
            registryLock.withLock {
                registered = session
            }
            Task.detached {
                await command()
                DisplayApplication.stop()
            }
            Task { @MainActor in
                session.startPump()
            }
            MainActor.assumeIsolated {
                DisplayApplication.run()
            }
        }

        /// Starts the pump that makes the window when the display is attached. It runs on the main actor.
        @MainActor
        private func startPump() {
            guard earlyFailureWindow == nil else {
                return
            }
            let pump = DisplayPump(display: display, showStatistics: showStatistics, inputSink: inputSink) {
                [stops, appCloseRequests, stopsAppOnClose] in
                if stopsAppOnClose {
                    appCloseRequests.continuation.yield(())
                } else {
                    stops.continuation.yield(())
                }
            }
            pump.start()
            self.pump = pump
            let updates = windowUpdates
            windowUpdateTask = Task { @MainActor [weak self] in
                for await update in updates {
                    guard let pump = self?.pump else {
                        continue
                    }
                    switch update {
                    case .title(let title):
                        pump.setWindowTitle(title)
                    case .status(let status):
                        pump.setPlaceholderStatus(status)
                    }
                }
            }
        }

        func publishWindowTitle(_ title: String) {
            windowUpdateContinuation.yield(.title(title))
        }

        func publishPlaceholderStatus(_ status: String) {
            windowUpdateContinuation.yield(.status(status))
        }

        @MainActor
        func showFailure(appName: String, message: String, remediation: String) -> Bool {
            if let pump {
                return pump.showFailure(appName: appName, message: message, remediation: remediation)
            }
            let failureWindow = SessionFailureWindowController(
                title: appName,
                appName: appName,
                message: message,
                remediation: remediation
            )
            let closeContinuation = appCloseRequests.continuation
            failureWindow.onClose = {
                closeContinuation.yield(())
            }
            failureWindow.show()
            earlyFailureWindow = failureWindow
            return true
        }

        func waitForAppWindowClose() async {
            for await _ in appCloseRequests.stream {
                return
            }
        }
    }
#endif
