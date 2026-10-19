#if APKRUN_EMBEDDED_RUNTIME
    import AppKit
    import Foundation
    import RuntimeHost
    import WindowingCore

    /// Turns the developer display's events into a window and its statistics line (`apkrun dev boot --window`).
    ///
    /// The pump runs on the main actor, next to the AppKit event loop. It makes the window when the display is attached,
    /// forwards each ready frame to the window, and updates the title once a second. With `--stats` it also logs each
    /// line to standard error. The window's pointer events go to `inputSink` (#024).
    @MainActor
    final class DisplayPump {
        private let display: DeveloperDisplay
        private let showStatistics: Bool
        private let inputSink: PointerInputSink
        private let onWindowClosed: @MainActor () -> Void
        private var source: SurfacePoolFrameSource?
        private var window: SessionWindowController?
        private var tasks: [Task<Void, Never>] = []
        #if APKRUN_TEST_READBACK
            private let tearing = TearingSampler()
        #endif

        init(
            display: DeveloperDisplay,
            showStatistics: Bool,
            inputSink: PointerInputSink,
            onWindowClosed: @escaping @MainActor () -> Void
        ) {
            self.display = display
            self.showStatistics = showStatistics
            self.inputSink = inputSink
            self.onWindowClosed = onWindowClosed
        }

        /// Starts the pump. It returns at once, and the events are handled on the main actor once the loop runs.
        func start() {
            tasks.append(
                Task { @MainActor in
                    for await event in display.events {
                        handle(event)
                    }
                    // The boot has ended, so the window goes with it.
                    stop()
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

        /// Stops the statistics and the frames, and closes the window.
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
                let window = SessionWindowController(
                    source: source, title: "APKRun display 0", backingScale: display.backingScale, inputSink: inputSink)
                window.onClose = onWindowClosed
                window.show()
                self.source = source
                self.window = window
            case .frameReady:
                #if APKRUN_TEST_READBACK
                    tearing.observe(event, surfaces: source?.surfaces ?? [])
                #endif
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
            let counters =
                "APKRun display 0  \(framesPerSecond) fps  dropped \(statistics.droppedFrames)  "
                + "stalls \(statistics.presentStalls)  hostReadbacks \(statistics.hostReadbacks)  "
                + "cpuPixelCopies \(statistics.cpuPixelCopies)"
            #if APKRUN_TEST_READBACK
                let line = counters + "  " + tearing.summary
            #else
                let line = counters
            #endif
            window.setTitle(line)
            Output.writeLogLine(line, toStandardError: true)
        }
    }
#endif
