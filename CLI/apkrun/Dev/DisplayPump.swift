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
        private var windowTitle = "APKRun display 0"
        private var placeholderStatus = "Starting Android…"
        private var source: SurfacePoolFrameSource?
        private var window: SessionWindowController?
        private var failureWindow: SessionFailureWindowController?
        private var tasks: [Task<Void, Never>] = []
        private var pendingGeometry: (pointSize: CGSize, backingScale: CGFloat, zoom: Double)?
        private var resizeCompletions: [@MainActor (DisplayResizeOutcome) -> Void] = []
        private var resizeTask: Task<Void, Never>?
        private var isShowingFailure = false
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
            cancelResize()
            window?.close()
            failureWindow?.close()
            failureWindow = nil
        }

        func setWindowTitle(_ title: String) {
            windowTitle = title
            window?.setAppName(title)
        }

        func setPlaceholderStatus(_ status: String) {
            placeholderStatus = status
            window?.setPlaceholderStatus(status)
        }

        func showFailure(appName: String, message: String, remediation: String) -> Bool {
            isShowingFailure = true
            cancelResize()
            if let window {
                window.showFailure(message: message, remediation: remediation)
                return true
            }
            let failureWindow = SessionFailureWindowController(
                title: appName,
                appName: appName,
                message: message,
                remediation: remediation
            )
            failureWindow.onClose = onWindowClosed
            failureWindow.show()
            self.failureWindow = failureWindow
            return true
        }

        private func handle(_ event: DeveloperDisplayEvent) {
            switch event {
            case .attached(let surfaceSet):
                guard failureWindow == nil else {
                    return
                }
                let source = SurfacePoolFrameSource(surfaceSet: surfaceSet, display: display)
                let window = SessionWindowController(
                    source: source,
                    title: windowTitle,
                    backingScale: display.backingScale,
                    inputSink: inputSink,
                    allowsResize: display.supportsWindowResize
                ) { [weak self] pointSize, backingScale, zoom, completion in
                    guard let self else {
                        completion(.rejected)
                        return
                    }
                    requestResize(
                        pointSize: pointSize,
                        backingScale: backingScale,
                        zoom: zoom,
                        completion: completion
                    )
                }
                window.onClose = onWindowClosed
                window.setPlaceholderStatus(placeholderStatus)
                window.show()
                self.source = source
                self.window = window
            case .surfacesReplaced(let surfaceSet):
                source?.ingest(.surfacesReplaced(surfaceSet: surfaceSet))
            case .frameReady:
                #if APKRUN_TEST_READBACK
                    tearing.observe(event, surfaces: source?.surfaces ?? [])
                #endif
                source?.ingest(event)
            }
        }

        private func requestResize(
            pointSize: CGSize,
            backingScale: CGFloat,
            zoom: Double,
            completion: @escaping @MainActor (DisplayResizeOutcome) -> Void
        ) {
            guard !isShowingFailure else {
                completion(.rejected)
                return
            }
            pendingGeometry = (pointSize, backingScale, zoom)
            resizeCompletions.append(completion)
            guard resizeTask == nil else {
                return
            }
            resizeTask = Task { @MainActor [weak self] in
                var lastResizeOutcome = DisplayResizeOutcome.unchanged
                while let self, !Task.isCancelled {
                    guard let geometry = pendingGeometry else {
                        break
                    }
                    pendingGeometry = nil
                    let previousGeneration = display.currentSurfaceSet?.generation
                    do {
                        try await display.resize(
                            pointSize: geometry.pointSize,
                            backingScale: geometry.backingScale,
                            zoom: geometry.zoom
                        )
                        if let surfaceSet = display.currentSurfaceSet {
                            if previousGeneration != surfaceSet.generation {
                                source?.ingest(.surfacesReplaced(surfaceSet: surfaceSet))
                                lastResizeOutcome = lastResizeOutcome.accumulating(.applied)
                            } else {
                                lastResizeOutcome = lastResizeOutcome.accumulating(.unchanged)
                            }
                        }
                    } catch let error as DeveloperDisplayResizeFailure {
                        switch error {
                        case .modeRestoreFailed(let hostModeRestored, let guestModeRestored):
                            lastResizeOutcome = lastResizeOutcome.accumulating(.stateUncertain)
                            Output.writeLogLine(
                                "error: display resize rollback failed (hostModeRestored=\(hostModeRestored), guestModeRestored=\(guestModeRestored)); input remains disabled until a newer display frame is committed",
                                toStandardError: true
                            )
                        case .geometry, .displayUnavailable:
                            lastResizeOutcome = lastResizeOutcome.accumulating(.rejected)
                            Output.writeLogLine(
                                "warning: display resize could not be applied (\(String(describing: error)))",
                                toStandardError: true
                            )
                        }
                    } catch {
                        lastResizeOutcome = lastResizeOutcome.accumulating(.rejected)
                        Output.writeLogLine(
                            "warning: display resize could not be applied (\(String(describing: error)))",
                            toStandardError: true
                        )
                    }
                }
                guard let self else {
                    return
                }
                let completions = resizeCompletions
                resizeCompletions.removeAll()
                resizeTask = nil
                for completion in completions {
                    completion(lastResizeOutcome)
                }
            }
        }

        private func cancelResize() {
            pendingGeometry = nil
            resizeTask?.cancel()
            resizeTask = nil
            let completions = resizeCompletions
            resizeCompletions.removeAll()
            for completion in completions {
                completion(.rejected)
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
