#if APKRUN_EMBEDDED_RUNTIME
    import Foundation
    import RuntimeHost
    import WindowingCore

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

        /// Whether `arguments` ask for `dev boot --window`. The check is on the words, because the loop starts before
        /// the arguments are parsed.
        static func isRequested(_ arguments: [String]) -> Bool {
            arguments.contains("boot") && arguments.contains("--window")
        }

        /// The display 0 of the boot. Its size is the scanout's mode, 1024 x 768, until #028 gives the image's default mode.
        let display = DeveloperDisplay(pixelWidth: 1024, pixelHeight: 768)
        /// Stop requests for the boot: Ctrl-C, or the window closing.
        let stops = AsyncStream.makeStream(of: Void.self)
        /// Whether the statistics go to standard error as well as to the window title.
        let showStatistics: Bool
        private var pump: DisplayPump?

        private init(showStatistics: Bool) {
            self.showStatistics = showStatistics
        }

        /// Runs `command` on a detached task, and the window's event loop on this thread, until the command ends.
        ///
        /// Call it on the main thread, from a context that is not an actor job: nothing is awaited before the loop starts.
        static func runEventLoop(showStatistics: Bool, command: @escaping @Sendable () async -> Void) {
            let session = DisplayWindowSession(showStatistics: showStatistics)
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
            DisplayApplication.run()
        }

        /// Starts the pump that makes the window when the display is attached. It runs on the main actor.
        @MainActor
        private func startPump() {
            let pump = DisplayPump(display: display, showStatistics: showStatistics) { [stops] in
                stops.continuation.yield()
            }
            pump.start()
            self.pump = pump
        }
    }
#endif
