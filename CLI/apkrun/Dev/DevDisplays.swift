#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Dispatch
    import Foundation
    import RuntimeAPI
    import RuntimeHost

    struct DevDisplaysCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "displays",
            abstract: "Manage Android virtual displays in a live development guest.",
            discussion: """
                Starts an embedded virgl Android guest and keeps it running while commands are entered.
                Commands run inside this session:
                  add --size 960x1700 --dpi 320
                  list
                  remove 1
                  quit

                The number passed to remove is the scanout shown by list. Closing this command releases
                displays created in this session and stops Android.
                """
        )

        @Option(
            name: .long,
            help: "The Guest Agent bundle directory (default: APKRUN_GUEST_DIR, then the app's Resources/guest)."
        )
        var guestDir: String?

        mutating func run() async throws {
            let stops = AsyncStream.makeStream(of: Void.self)
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

            let console = DevDisplaysConsole()
            let options = DevBootOptions(
                gpu: .virgl,
                guestAgentDirectory: DevGuestAgentLocation.directory(
                    guestDir: guestDir,
                    environment: ProcessInfo.processInfo.environment,
                    executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                )
            )
            Output.write("Starting Android with the virgl GPU profile for display management.")
            Output.write("Use `add --size WIDTHxHEIGHT --dpi DPI`, `list`, `remove SCANOUT`, or `quit`.")

            try await DevBoot().run(
                options: options,
                stopRequests: stops.stream,
                onRuntimeReady: { context in
                    guard let control = await context.makeDisplayControl() else {
                        throw RuntimeWireError.runtime(
                            "guestAgentUnavailable",
                            message: "The Android display pool is unavailable.",
                            remediation:
                                "Run this command with a development image that includes the Guest Agent and virgl GPU support."
                        )
                    }
                    await console.start(control: control, stop: stops.continuation)
                    return nil
                },
                onEvent: { event in
                    switch event {
                    case .state(let state):
                        Output.writeLogLine("state: \(state)", toStandardError: true)
                    case .console, .windowStatus, .windowTitle:
                        break
                    case .message(let text):
                        Output.writeLogLine(text, toStandardError: true)
                    case .warning(let text):
                        Output.writeLogLine("warning: \(text)", toStandardError: true)
                    case .catalogWarning(let error):
                        ErrorOutput.write(error, json: false)
                    }
                }
            )
            await console.stop()
        }
    }

    private actor DevDisplaysConsole {
        private var control: DevelopmentDisplayControl?
        private var inputTask: Task<Void, Never>?

        func start(control: DevelopmentDisplayControl, stop: AsyncStream<Void>.Continuation) {
            guard inputTask == nil else {
                return
            }
            self.control = control
            inputTask = Task {
                await readCommands(stop: stop)
            }
        }

        func stop() {
            inputTask?.cancel()
            inputTask = nil
            control = nil
        }

        private func readCommands(stop: AsyncStream<Void>.Continuation) async {
            Output.writeLogLine("displays> ", toStandardError: true)
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    guard !Task.isCancelled else {
                        return
                    }
                    do {
                        let input = try DevDisplaysInputParser.parse(line)
                        if await handle(input) {
                            await releaseAll()
                            stop.yield(())
                            return
                        }
                    } catch {
                        ErrorOutput.write(error, json: false)
                    }
                    Output.writeLogLine("displays> ", toStandardError: true)
                }
            } catch is CancellationError {
                return
            } catch {
                Output.writeLogLine("warning: could not read display commands: \(error)", toStandardError: true)
            }
            await releaseAll()
            stop.yield(())
        }

        /// Returns true when the command ends the development session.
        private func handle(_ input: DevDisplaysInput) async -> Bool {
            guard let control else {
                return true
            }
            switch input {
            case .add(let width, let height, let dpi):
                do {
                    let record = try await control.add(width: width, height: height, densityDPI: dpi)
                    let androidID = record.androidDisplayID.map(String.init) ?? "unknown"
                    Output.write(
                        "Added scanout \(record.scanout): Android display \(androidID), "
                            + "\(record.widthPixels ?? width)x\(record.heightPixels ?? height) at "
                            + "\(record.densityDPI ?? dpi) dpi."
                    )
                } catch {
                    ErrorOutput.write(error, json: false)
                }
                return false
            case .list:
                let snapshots = await control.list()
                Output.write("SCANOUT  STATE       ANDROID ID  MODE          DPI    MEMORY")
                for record in snapshots {
                    let androidID = record.androidDisplayID.map(String.init) ?? "—"
                    let mode: String
                    let dpi: String
                    if let width = record.widthPixels, let height = record.heightPixels {
                        mode = "\(width)x\(height)"
                        dpi = record.densityDPI.map(String.init) ?? "—"
                    } else {
                        mode = "—"
                        dpi = "—"
                    }
                    let memory =
                        record.estimatedSurfaceBytes == 0
                        ? "—"
                        : ByteCountFormatter.string(
                            fromByteCount: record.estimatedSurfaceBytes,
                            countStyle: .memory
                        )
                    Output.write(
                        "\(record.scanout)\t\t\(record.state)\t\(androidID)\t\t\(mode)\t\(dpi)\t\(memory)"
                    )
                }
                return false
            case .remove(let scanout):
                switch await control.remove(scanout: scanout) {
                case .notOwned:
                    Output.writeLogLine(
                        "error: scanout \(scanout) is not leased by this command.", toStandardError: true)
                case .removed:
                    Output.write("Removed scanout \(scanout).")
                case .quarantined(let androidDisplayID):
                    Output.writeLogLine(
                        "warning: Android did not confirm removal of display \(androidDisplayID); "
                            + "scanout \(scanout) stays quarantined. Restart Android before reusing it.",
                        toStandardError: true
                    )
                case .staleLease:
                    Output.writeLogLine(
                        "error: scanout \(scanout) lease expired before removal completed. "
                            + "Run `list` and restart Android if it remains faulted.",
                        toStandardError: true
                    )
                }
                return false
            case .help:
                Output.write("add --size WIDTHxHEIGHT --dpi DPI  Create a virtual display (DPI range: 120–640).")
                Output.write("list                             Show scanout, Android ID, mode, and memory.")
                Output.write("remove SCANOUT                   Release a display created in this session.")
                Output.write("quit                             Release displays and stop Android.")
                return false
            case .quit:
                return true
            case .empty:
                return false
            }
        }

        private func releaseAll() async {
            if let control {
                await control.releaseAll()
            }
        }
    }
#endif
