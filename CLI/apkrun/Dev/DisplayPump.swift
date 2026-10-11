#if APKRUN_EMBEDDED_RUNTIME
    import AppKit
    import Foundation
    import RuntimeHost
    import WindowingCore

    /// Turns the developer display's events into a window and its statistics line (`apkrun dev boot --window`).
    ///
    /// The pump runs on the main actor, next to the AppKit event loop. It makes the window when the display is attached,
    /// forwards each ready frame to the window, and updates the title once a second. With `--stats` it also logs each
    /// line to standard error.
    @MainActor
    final class DisplayPump {
        private let display: DeveloperDisplay
        private let showStatistics: Bool
        private let onWindowClosed: @MainActor () -> Void
        private var source: SurfacePoolFrameSource?
        private var window: DisplayWindow?
        private var tasks: [Task<Void, Never>] = []

        init(display: DeveloperDisplay, showStatistics: Bool, onWindowClosed: @escaping @MainActor () -> Void) {
            self.display = display
            self.showStatistics = showStatistics
            self.onWindowClosed = onWindowClosed
        }

        /// Starts the pump. Call it on the main actor, before the event loop runs.
        func start() {
            tasks.append(
                Task { @MainActor in
                    for await event in display.events {
                        handle(event)
                    }
                }
            )
            tasks.append(
                Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        updateStatistics()
                    }
                }
            )
        }

        /// Stops the pump and closes the window. The boot has ended.
        func stop() {
            for task in tasks {
                task.cancel()
            }
            tasks.removeAll()
            window?.close()
        }

        private func handle(_ event: DeveloperDisplayEvent) {
            switch event {
            case .attached(let surfaces):
                let source = SurfacePoolFrameSource(surfaces: surfaces, generation: 1, display: display)
                let scale = NSScreen.main?.backingScaleFactor ?? 1
                let window = DisplayWindow(source: source, title: "APKRun display 0", backingScale: scale)
                window.onClose = onWindowClosed
                window.show()
                self.source = source
                self.window = window
            case .frameReady:
                source?.ingest(event)
            }
        }

        private var lastFramesPresented: UInt64 = 0

        private func updateStatistics() {
            guard let window, let statistics = display.statistics else {
                return
            }
            let framesPerSecond = statistics.framesPresented &- lastFramesPresented
            lastFramesPresented = statistics.framesPresented
            guard showStatistics else {
                return
            }
            let line =
                "APKRun display 0  \(framesPerSecond) fps  dropped \(statistics.droppedFrames)  "
                + "stalls \(statistics.presentStalls)  hostReadbacks \(statistics.hostReadbacks)  "
                + "cpuPixelCopies \(statistics.cpuPixelCopies)"
            window.setTitle(line)
            Output.writeLogLine(line, toStandardError: true)
        }
    }
#endif
