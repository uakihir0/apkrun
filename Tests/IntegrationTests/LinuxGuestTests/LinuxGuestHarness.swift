import Darwin
import DiagnosticsCore
import Foundation
import VirtioDeviceCore
import XCTest

@testable import VirtualMachineCore

// UNCHECKED-SENDABLE: the lock protects the bounded console attachment buffer.
final class LinuxGuestConsoleCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var bytes = Data()
    private var omittedByteCount: UInt64 = 0

    init(maximumBytes: Int = 4 * 1_024 * 1_024) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    func append(_ data: Data) {
        lock.withLock {
            if data.count >= maximumBytes {
                omittedByteCount &+= UInt64(bytes.count + data.count - maximumBytes)
                bytes = Data(data.suffix(maximumBytes))
                return
            }

            let excess = max(0, bytes.count + data.count - maximumBytes)
            if excess > 0 {
                bytes.removeFirst(excess)
                omittedByteCount &+= UInt64(excess)
            }
            bytes.append(data)
        }
    }

    func snapshot() -> (bytes: Data, omittedByteCount: UInt64) {
        lock.withLock { (bytes, omittedByteCount) }
    }
}

private final class FailedLinuxGuestControllerRetention: @unchecked Sendable {
    static let shared = FailedLinuxGuestControllerRetention()

    private let lock = NSLock()
    private var controllers: [UUID: VMController] = [:]

    func retainUntilReleased(_ controller: VMController) {
        let identifier = UUID()
        lock.withLock {
            controllers[identifier] = controller
        }

        Task.detached { [weak self, controller] in
            while !Task.isCancelled {
                let state = await controller.state
                if state == .stopped {
                    self?.release(identifier)
                    return
                }
                if case .failed = state {
                    do {
                        try await controller.reset()
                        self?.release(identifier)
                        return
                    } catch {
                        // Keep the controller alive and retry after the VZ callback can drain.
                    }
                } else if state == .running || state == .paused || state == .stopping {
                    try? await controller.stop()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func release(_ identifier: UUID) {
        _ = lock.withLock {
            controllers.removeValue(forKey: identifier)
        }
    }
}

private final class LinuxGuestNetworkHealthCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [VMNetworkHealthState] = []

    func append(_ state: VMNetworkHealthState) {
        lock.withLock {
            states.append(state)
        }
    }

    func snapshot() -> [VMNetworkHealthState] {
        lock.withLock { states }
    }
}

enum LinuxGuestHarness {
    enum StopBehavior: Equatable {
        case guestPowerOff
        case requestPowerButton
        case forced
        case observeGuestReboot
        case observeGuestPanic
        case forcedAfterConsoleLine(String)
        case forcedAfterConsoleLineDelay(String, Duration)
    }

    enum RebootObservation: Equatable {
        case guestRestarted
        case guestDidStop
        case noRestartObserved
    }

    struct RunResult {
        let records: [TestGuestRecord]
        let states: [VMState]
        let networkHealthStates: [VMNetworkHealthState]
        let networkHealthResult: HealthResult?
        let rebootObservation: RebootObservation?
        let consoleOutput: Data
        let consoleOutputDroppedByteCount: UInt64
        let consoleLog: Data
        let bootLog: Data
        let consoleLogDroppedByteCount: UInt64
    }

    enum HarnessEvent: Sendable {
        case record(TestGuestRecord)
        case state(VMState)
        case consoleMarkerSeen(String)
        case consoleStreamEnded
        case rebootProbeTimedOut
    }

    enum HarnessFailure: Error, Equatable {
        case missingArtifacts(String)
        case invalidArtifactDirectory(String)
        case timedOut
        case consoleEnded
        case startUnexpectedlySucceeded
        case unexpectedStartFailure
        case guestCheckFailed(name: String, detail: String)
        case cleanupFailed
        case guestFinishedBeforeRestartMarker
        case guestStoppedBeforeRestartMarker
        case guestVMFailedDuringRebootObservation
        case consoleMarkerNotObserved(String)
        case consoleLogMissing
    }

    static func run(
        testCase: XCTestCase,
        stopBehavior: StopBehavior,
        powerOff: Bool,
        tests: [String] = [],
        initrd: URL? = nil,
        blockDisks: LinuxTestGuest.BlockDisks? = nil,
        blockDiskOrder: LinuxTestGuest.BlockDiskOrder = .readOnlyThenReadWrite,
        customDevices: [any VirtioDeviceModel] = [],
        entropyTestDevice: EntropyTestDevice? = nil,
        recordObserver: (@Sendable (TestGuestRecord) -> Void)? = nil,
        hostAction: (@Sendable (VMController) async throws -> Void)? = nil,
        extraCommandLine: [String] = [],
        logSink: (any LogSink)? = nil
    ) async throws -> RunResult {
        let artifacts = try artifactURLs()
        let initrdURL = initrd ?? artifacts.initrd
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-linux-guest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        var preserveRunDirectory = false
        defer {
            if !preserveRunDirectory {
                try? FileManager.default.removeItem(at: runDirectory)
            }
        }

        let definition = LinuxTestGuest.definition(
            kernel: artifacts.kernel,
            initrd: initrdURL,
            tests: tests,
            blockDisks: blockDisks,
            blockDiskOrder: blockDiskOrder,
            customDevices: customDevices,
            entropyTestDevice: entropyTestDevice,
            powerOff: powerOff,
            extraCommandLine: extraCommandLine
        )
        let validated = try VMDefinitionValidator().validate(definition)
        let paths = APKRunPaths(
            allowingHomeOverride: true,
            environment: ["APKRUN_HOME": runDirectory.appending(path: "data").path]
        )
        let liveDiagnostics = DiagnosticsContext.live(paths: paths)
        let diagnostics = DiagnosticsContext(
            logSink: logSink ?? liveDiagnostics.logSink,
            healthChecks: HealthCheckRegistry(),
            perfTimeline: liveDiagnostics.perfTimeline,
            paths: paths,
            clock: liveDiagnostics.clock,
            buildInfo: liveDiagnostics.buildInfo,
            hostProbe: liveDiagnostics.hostProbe
        )
        let controller = VMController(definition: validated, diagnostics: diagnostics)
        try await VMHealthChecks.register(in: diagnostics.healthChecks, controller: controller)
        let networkLogger = APKLogger(category: .network, sink: diagnostics.logSink)
        let console = controller.console(.systemConsole)
        let parserByteStream = console.makeByteStream()
        let tailCaptureByteStream = console.makeByteStream(
            bufferingPolicy: .preserveNewest
        )
        let records = AsyncStream.makeStream(
            of: TestGuestRecord.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        let events = AsyncStream.makeStream(
            of: HarnessEvent.self,
            bufferingPolicy: .unbounded
        )
        var consoleMarkers: [(name: String, bytes: Data)] = []
        if case .forcedAfterConsoleLine(let marker) = stopBehavior {
            consoleMarkers.append((name: marker, bytes: Data(marker.utf8)))
        } else if case .forcedAfterConsoleLineDelay(let marker, _) = stopBehavior {
            consoleMarkers.append((name: marker, bytes: Data(marker.utf8)))
        }
        if stopBehavior == .observeGuestPanic {
            consoleMarkers.append(contentsOf: [
                (name: "Kernel panic", bytes: Data("Kernel panic".utf8)),
                (name: "Call trace:", bytes: Data("Call trace:".utf8)),
            ])
        }
        if tests.contains("ports") {
            consoleMarkers.append(contentsOf: [
                (name: "APKRUN-PORT-READY-1", bytes: Data("APKRUN-PORT-READY-1\n".utf8)),
                (name: "APKRUN-PORT-READY-2", bytes: Data("APKRUN-PORT-READY-2\n".utf8)),
            ])
        }
        let maximumConsoleMarkerLength = consoleMarkers.map(\.bytes.count).max() ?? 0
        let consoleCapture = LinuxGuestConsoleCapture()
        let parserTask = Task {
            var parser = TestGuestLineParser()
            var markerSearchBuffer = Data()
            var pendingMarkers = Set(consoleMarkers.map(\.name))
            for await bytes in parserByteStream.stream {
                guard !Task.isCancelled else { break }
                if !pendingMarkers.isEmpty {
                    markerSearchBuffer.append(bytes)
                    for marker in consoleMarkers where pendingMarkers.contains(marker.name) {
                        if Self.consoleMarkerMatches(marker.bytes, in: markerSearchBuffer) {
                            pendingMarkers.remove(marker.name)
                            events.continuation.yield(.consoleMarkerSeen(marker.name))
                        }
                    }
                    Self.retainConsoleMarkerSearchTail(
                        &markerSearchBuffer,
                        maximumMarkerLength: maximumConsoleMarkerLength
                    )
                }
                for record in parser.consume(bytes) {
                    records.continuation.yield(record)
                    Self.logNetworkLease(from: record, using: networkLogger)
                    recordObserver?(record)
                    events.continuation.yield(.record(record))
                }
            }
            if !Task.isCancelled {
                for record in parser.finish() {
                    records.continuation.yield(record)
                    Self.logNetworkLease(from: record, using: networkLogger)
                    recordObserver?(record)
                    events.continuation.yield(.record(record))
                }
                events.continuation.yield(.consoleStreamEnded)
            }
            records.continuation.finish()
        }
        let captureTask = Task {
            for await bytes in tailCaptureByteStream.stream {
                guard !Task.isCancelled else { break }
                consoleCapture.append(bytes)
            }
        }

        let stateStream = AsyncStream.makeStream(of: VMState.self, bufferingPolicy: .unbounded)
        let stateTask = Task {
            for await state in controller.stateUpdates {
                guard !Task.isCancelled else { break }
                stateStream.continuation.yield(state)
                events.continuation.yield(.state(state))
            }
            stateStream.continuation.finish()
        }
        let networkHealthCapture = LinuxGuestNetworkHealthCapture()
        let networkHealthTask = Task {
            for await state in controller.networkHealthUpdates {
                guard !Task.isCancelled else { break }
                networkHealthCapture.append(state)
            }
        }

        do {
            try await controller.start()
            if let hostAction {
                try await hostAction(controller)
            }
            if tests.contains("ports") {
                try await waitForConsoleMarker(
                    "APKRUN-PORT-READY-1",
                    events: events.stream,
                    timeout: .seconds(60)
                )
                try controller.console(.service(name: "test-1"))
                    .writeHostInput(Data("APKRUN-PORT-1\n".utf8))
                try await waitForConsoleMarker(
                    "APKRUN-PORT-READY-2",
                    events: events.stream,
                    timeout: .seconds(60)
                )
                try controller.console(.service(name: "test-2"))
                    .writeHostInput(Data("APKRUN-PORT-2\n".utf8))
            }
            let observedRecords: [TestGuestRecord]
            let observedStates: [VMState]
            let rebootObservation: RebootObservation?
            if case .forcedAfterConsoleLine(let marker) = stopBehavior {
                try await waitForConsoleMarker(
                    marker,
                    events: events.stream,
                    timeout: .seconds(60)
                )
                try await controller.stop()
                await waitForConsoleTask(parserTask)
                observedRecords = await collectRecords(records.stream)
                rebootObservation = nil
                observedStates = try await statesThroughGuestStop(
                    stateStream.stream,
                    timeout: .seconds(60)
                )
            } else if case .forcedAfterConsoleLineDelay(let marker, let delay) = stopBehavior {
                try await waitForConsoleMarker(
                    marker,
                    events: events.stream,
                    timeout: .seconds(60)
                )
                try await Task.sleep(for: delay)
                try await controller.stop()
                await waitForConsoleTask(parserTask)
                observedRecords = await collectRecords(records.stream)
                rebootObservation = nil
                observedStates = try await statesThroughGuestStop(
                    stateStream.stream,
                    timeout: .seconds(60)
                )
            } else if stopBehavior == .observeGuestPanic {
                observedRecords = try await recordsUntilDone(records.stream)
                try await waitForConsoleMarker(
                    "Kernel panic",
                    events: events.stream,
                    timeout: .seconds(60),
                    allowGuestDone: true,
                    allowGuestTerminalState: true
                )
                try await waitForConsoleMarker(
                    "Call trace:",
                    events: events.stream,
                    timeout: .seconds(60),
                    allowGuestDone: true,
                    allowGuestTerminalState: true
                )
                let panicState = await controller.state
                if panicState == .running || panicState == .paused || panicState == .stopping {
                    do {
                        try await controller.stop()
                    } catch {
                        let stateAfterStopFailure = await controller.state
                        if case .failed = stateAfterStopFailure {
                            try await controller.reset()
                        } else if stateAfterStopFailure != .stopped {
                            throw error
                        }
                    }
                } else if case .failed = panicState {
                    try await controller.reset()
                }
                rebootObservation = nil
                observedStates = try await statesThroughGuestStop(
                    stateStream.stream,
                    timeout: .seconds(60)
                )
            } else if stopBehavior == .observeGuestReboot {
                let observation = try await observeGuestReboot(
                    events: events.stream,
                    continuation: events.continuation
                )
                observedRecords = observation.records
                rebootObservation = observation.outcome

                switch observation.outcome {
                case .guestRestarted, .noRestartObserved:
                    let state = await controller.state
                    if state == .running || state == .paused {
                        try await controller.stop()
                    }
                    observedStates = try await statesThroughGuestStop(
                        stateStream.stream,
                        timeout: .seconds(10)
                    )
                case .guestDidStop:
                    observedStates = try await statesThroughGuestStop(
                        stateStream.stream,
                        timeout: .seconds(10)
                    )
                }
            } else {
                observedRecords = try await recordsUntilDone(records.stream)
                rebootObservation = nil
                switch stopBehavior {
                case .guestPowerOff:
                    break
                case .requestPowerButton:
                    try await controller.requestGuestStop()
                case .forced:
                    try await controller.stop()
                case .observeGuestReboot:
                    preconditionFailure("Reboot observation is handled above.")
                case .observeGuestPanic, .forcedAfterConsoleLine,
                    .forcedAfterConsoleLineDelay:
                    preconditionFailure("The specialized console probe is handled above.")
                }

                let stateTimeout: Duration =
                    stopBehavior == .requestPowerButton ? .seconds(10) : .seconds(60)
                observedStates = try await statesThroughGuestStop(
                    stateStream.stream,
                    timeout: stateTimeout
                )
                if stopBehavior == .requestPowerButton {
                    XCTAssertEqual(
                        observedStates,
                        [.stopped, .starting, .running, .stopping, .stopped]
                    )
                }
            }
            events.continuation.finish()
            await waitForConsoleTask(parserTask)
            await waitForConsoleTask(captureTask)
            networkHealthTask.cancel()
            await networkHealthTask.value
            let networkHealthResult: HealthResult?
            if tests.contains("net") {
                let healthResults = await diagnostics.healthChecks.run(
                    deep: false,
                    context: diagnostics.healthContext(
                        daemonAvailable: true,
                        runtimeRunning: true
                    )
                )
                networkHealthResult = healthResults.first { $0.id == "vm.network" }
            } else {
                networkHealthResult = nil
            }
            stateTask.cancel()
            await stateTask.value
            await controller.waitForConsoleLogDrain()
            attachConsole(
                consoleCapture.snapshot(),
                parserOmittedByteCount: parserByteStream.droppedByteCount,
                tailOmittedByteCount: tailCaptureByteStream.droppedByteCount,
                to: testCase
            )
            let consoleLog = try readConsoleLog(at: paths.consoleLogFile)
            let bootLog = try readLatestBootLog(in: paths.vmLogsDirectory)
            let capturedConsole = consoleCapture.snapshot()
            return RunResult(
                records: observedRecords,
                states: observedStates,
                networkHealthStates: networkHealthCapture.snapshot(),
                networkHealthResult: networkHealthResult,
                rebootObservation: rebootObservation,
                consoleOutput: capturedConsole.bytes,
                consoleOutputDroppedByteCount: parserByteStream.droppedByteCount
                    &+ tailCaptureByteStream.droppedByteCount
                    &+ capturedConsole.omittedByteCount,
                consoleLog: consoleLog,
                bootLog: bootLog,
                consoleLogDroppedByteCount: await controller.consoleLogWriterDroppedByteCount()
            )
        } catch {
            events.continuation.finish()
            networkHealthTask.cancel()
            await networkHealthTask.value
            preserveRunDirectory = !(await cleanup(controller))
            stateTask.cancel()
            await stateTask.value
            await waitForConsoleTask(parserTask)
            await waitForConsoleTask(captureTask)
            attachConsole(
                consoleCapture.snapshot(),
                parserOmittedByteCount: parserByteStream.droppedByteCount,
                tailOmittedByteCount: tailCaptureByteStream.droppedByteCount,
                to: testCase
            )
            if preserveRunDirectory {
                testCase.add(
                    XCTAttachment(
                        string: "VM resources did not release cleanly. Console logs retained at \(runDirectory.path)"
                    )
                )
                throw HarnessFailure.cleanupFailed
            }
            throw error
        }
    }

    private static func logNetworkLease(
        from record: TestGuestRecord,
        using logger: APKLogger
    ) {
        guard case .check(name: "net", result: .ok, let detail) = record else {
            return
        }

        var fields: [String: String] = [:]
        for token in detail.split(whereSeparator: \.isWhitespace) {
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, fields[pair[0]] == nil else { return }
            fields[pair[0]] = pair[1]
        }
        guard
            let address = fields["ip"],
            let gateway = fields["gw"],
            let dns = fields["dns"],
            fields["http"] == "204",
            fields["ext"].map({ $0 == "204" }) != false,
            isIPv4(address),
            isIPv4(gateway),
            isIPv4(dns)
        else {
            return
        }

        logger.info(
            "lease interface=eth0 ip=\(address, .public) gw=\(gateway, .public) dns=\(dns, .public)"
        )
    }

    private static func isIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString {
            inet_pton(AF_INET, $0, &address) == 1
        }
    }

    private static func cleanup(_ controller: VMController) async -> Bool {
        var state = await controller.state
        if state == .running || state == .paused || state == .stopping {
            try? await controller.stop()
            state = await controller.state
        }
        if case .failed = state {
            try? await controller.reset()
            state = await controller.state
        }
        guard state == .stopped else {
            FailedLinuxGuestControllerRetention.shared.retainUntilReleased(controller)
            return false
        }
        await controller.waitForConsoleLogDrain()
        return true
    }

    static func verifyFailedStartCanReset() async throws -> VZErrorInfo {
        let artifacts = try artifactURLs()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-failed-start-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let kernelCopy = temporaryDirectory.appendingPathComponent("Image")
        try FileManager.default.copyItem(at: artifacts.kernel, to: kernelCopy)
        let definition = LinuxTestGuest.definition(
            kernel: kernelCopy,
            initrd: artifacts.initrd
        )
        let validated = try VMDefinitionValidator().validate(definition)
        try FileManager.default.removeItem(at: kernelCopy)

        let controller = VMController(
            definition: validated,
            diagnostics: DiagnosticsContext.live(
                paths: APKRunPaths(
                    allowingHomeOverride: true,
                    environment: [
                        "APKRUN_HOME": temporaryDirectory.appending(path: "data").path
                    ]
                )
            )
        )
        let failure: VMFailure
        do {
            try await controller.start()
            throw HarnessFailure.startUnexpectedlySucceeded
        } catch let startFailure as VMFailure {
            failure = startFailure
        }
        guard case .startFailed(let errorInfo) = failure else {
            throw HarnessFailure.unexpectedStartFailure
        }
        let failedState = await controller.state
        guard case .failed(let stateFailure) = failedState, stateFailure == failure else {
            throw HarnessFailure.unexpectedStartFailure
        }
        try await controller.reset()
        let resetState = await controller.state
        guard resetState == .stopped else {
            throw HarnessFailure.unexpectedStartFailure
        }
        return errorInfo
    }

    static func artifactURLs() throws -> (kernel: URL, initrd: URL) {
        let artifactDirectory: URL
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let documentsDirectory =
            homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
        let configuredDirectory =
            ProcessInfo.processInfo.environment["APKRUN_TEST_LINUX_DIR"]
            ?? Bundle.main.object(forInfoDictionaryKey: "APKRUN_TEST_LINUX_DIR") as? String
        artifactDirectory = try selectedArtifactDirectory(
            configuredDirectory: configuredDirectory,
            defaultDirectory: URL(
                fileURLWithPath: "/tmp/apkrun-test-linux",
                isDirectory: true
            ),
            homeDirectory: homeDirectory
        )
        guard !isLexicallyWithin(artifactDirectory, directory: documentsDirectory) else {
            throw HarnessFailure.invalidArtifactDirectory(
                "APKRUN_TEST_LINUX_DIR must be outside ~/Documents to avoid macOS "
                    + "file-access approval prompts."
            )
        }
        let kernel = artifactDirectory.appendingPathComponent("Image")
        let initrd = artifactDirectory.appendingPathComponent("initramfs.cpio.gz")
        guard
            FileManager.default.isReadableFile(atPath: kernel.path),
            FileManager.default.isReadableFile(atPath: initrd.path)
        else {
            let message =
                "Linux test artifacts are missing. Run scripts/fetch-test-linux.sh and scripts/build-test-initramfs.sh."
            let isCI =
                ProcessInfo.processInfo.environment["APKRUN_CI"] == "1"
                || Bundle.main.object(forInfoDictionaryKey: "APKRUN_CI") as? String == "1"
            if isCI {
                throw HarnessFailure.missingArtifacts(message)
            }
            throw XCTSkip(message)
        }
        return (kernel, initrd)
    }

    static func isLexicallyWithin(_ url: URL, directory: URL) -> Bool {
        let path = lexicallyStandardizedPath(url.path).lowercased()
        let root = lexicallyStandardizedPath(directory.path).lowercased()
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func resolvedArtifactDirectory(
        _ url: URL,
        homeDirectory: URL
    ) throws -> URL {
        let documentsDirectory =
            homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
        guard !isLexicallyWithin(url, directory: documentsDirectory) else {
            throw HarnessFailure.invalidArtifactDirectory(
                "APKRUN_TEST_LINUX_DIR must be outside ~/Documents to avoid macOS "
                    + "file-access approval prompts."
            )
        }
        let resolvedHomeDirectory = try resolvePathWithoutEnteringProtected(
            homeDirectory,
            protectedDirectories: []
        )
        let protectedDirectories = [
            documentsDirectory,
            resolvedHomeDirectory.appendingPathComponent("Documents", isDirectory: true),
        ]
        return try resolvePathWithoutEnteringProtected(
            url,
            protectedDirectories: protectedDirectories
        )
    }

    static func selectedArtifactDirectory(
        configuredDirectory: String?,
        defaultDirectory: URL,
        homeDirectory: URL
    ) throws -> URL {
        let requestedDirectory: URL
        if let override = configuredDirectory, !override.isEmpty {
            guard override.hasPrefix("/") else {
                throw HarnessFailure.invalidArtifactDirectory(
                    "APKRUN_TEST_LINUX_DIR must be an absolute path, such as /tmp/apkrun-test-linux."
                )
            }
            requestedDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            requestedDirectory = defaultDirectory
        }
        return try resolvedArtifactDirectory(requestedDirectory, homeDirectory: homeDirectory)
    }

    private static func resolvePathWithoutEnteringProtected(
        _ url: URL,
        protectedDirectories: [URL]
    ) throws -> URL {
        var resolvedPath = "/"
        var unresolvedComponents: [String] = []
        var remainingComponents = url.path.split(separator: "/").map(String.init)
        var followedLinks = 0

        while !remainingComponents.isEmpty {
            let component = remainingComponents.removeFirst()
            if component.isEmpty || component == "." {
                continue
            }
            if !unresolvedComponents.isEmpty {
                if component == ".." {
                    unresolvedComponents.removeLast()
                } else {
                    unresolvedComponents.append(component)
                }
                let unresolvedPath = unresolvedComponents.reduce(resolvedPath) {
                    $0 == "/" ? "/\($1)" : "\($0)/\($1)"
                }
                guard
                    !protectedDirectories.contains(where: {
                        isPathWithin(unresolvedPath, directory: $0.path)
                    })
                else {
                    throw HarnessFailure.invalidArtifactDirectory(
                        "APKRUN_TEST_LINUX_DIR must be outside ~/Documents to avoid macOS "
                            + "file-access approval prompts."
                    )
                }
                continue
            }
            if component == ".." {
                resolvedPath = (resolvedPath as NSString).deletingLastPathComponent
                guard
                    !protectedDirectories.contains(where: {
                        isPathWithin(resolvedPath, directory: $0.path)
                    })
                else {
                    throw HarnessFailure.invalidArtifactDirectory(
                        "APKRUN_TEST_LINUX_DIR must be outside ~/Documents to avoid macOS "
                            + "file-access approval prompts."
                    )
                }
                continue
            }

            let candidatePath = resolvedPath == "/" ? "/\(component)" : "\(resolvedPath)/\(component)"
            guard
                !protectedDirectories.contains(where: {
                    isPathWithin(candidatePath, directory: $0.path)
                })
            else {
                throw HarnessFailure.invalidArtifactDirectory(
                    "APKRUN_TEST_LINUX_DIR must be outside ~/Documents to avoid macOS "
                        + "file-access approval prompts."
                )
            }

            var fileStatus = stat()
            let status = candidatePath.withCString { lstat($0, &fileStatus) }
            if status != 0 {
                guard errno == ENOENT || errno == ENOTDIR else {
                    throw HarnessFailure.invalidArtifactDirectory(
                        "Could not safely resolve APKRUN_TEST_LINUX_DIR."
                    )
                }
                unresolvedComponents.append(component)
                continue
            }

            if (fileStatus.st_mode & S_IFMT) == S_IFLNK {
                followedLinks += 1
                guard followedLinks <= 40 else {
                    throw HarnessFailure.invalidArtifactDirectory(
                        "Could not safely resolve APKRUN_TEST_LINUX_DIR."
                    )
                }
                var targetBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let targetLength = candidatePath.withCString { path in
                    targetBuffer.withUnsafeMutableBufferPointer { buffer in
                        readlink(path, buffer.baseAddress, buffer.count)
                    }
                }
                guard targetLength >= 0, targetLength < targetBuffer.count else {
                    throw HarnessFailure.invalidArtifactDirectory(
                        "Could not safely resolve APKRUN_TEST_LINUX_DIR."
                    )
                }
                let target = String(
                    decoding: targetBuffer[..<targetLength].map { UInt8(bitPattern: $0) },
                    as: UTF8.self
                )
                if target.hasPrefix("/") {
                    resolvedPath = "/"
                }
                remainingComponents =
                    target.split(separator: "/").map(String.init)
                    + remainingComponents
                continue
            }

            resolvedPath = candidatePath
        }

        let finalPath = unresolvedComponents.reduce(resolvedPath) {
            $0 == "/" ? "/\($1)" : "\($0)/\($1)"
        }
        return URL(fileURLWithPath: finalPath, isDirectory: true)
    }

    private static func isPathWithin(_ path: String, directory: String) -> Bool {
        let candidate = lexicallyStandardizedPath(path).lowercased()
        let root = lexicallyStandardizedPath(directory).lowercased()
        return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func lexicallyStandardizedPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".", "":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func isWithin(_ url: URL, directory: URL) -> Bool {
        let path = resolvedPath(url).path.lowercased()
        let root = resolvedPath(directory).path.lowercased()
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func resolvedPath(_ url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL
        var existingPath = standardizedURL.path
        var missingComponents: [String] = []

        while !FileManager.default.fileExists(atPath: existingPath) {
            let existingURL = URL(fileURLWithPath: existingPath, isDirectory: true)
            let component = existingURL.lastPathComponent
            guard !component.isEmpty, component != "/" else {
                return standardizedURL
            }
            missingComponents.insert(component, at: 0)
            existingPath = existingURL.deletingLastPathComponent().path
        }

        var resolvedURL = URL(fileURLWithPath: existingPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        for component in missingComponents {
            resolvedURL.appendPathComponent(component)
        }
        return resolvedURL.standardizedFileURL
    }

    private static func recordsUntilDone(
        _ stream: AsyncStream<TestGuestRecord>
    ) async throws -> [TestGuestRecord] {
        try await withThrowingTaskGroup(of: [TestGuestRecord].self) { group in
            group.addTask {
                var observed: [TestGuestRecord] = []
                for await record in stream {
                    observed.append(record)
                    if case .check(
                        name: let name,
                        result: .fail,
                        detail: let detail
                    ) = record {
                        throw HarnessFailure.guestCheckFailed(name: name, detail: detail)
                    }
                    if record == .done {
                        return observed
                    }
                }
                throw HarnessFailure.consoleEnded
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw HarnessFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw HarnessFailure.consoleEnded
            }
            return result
        }
    }

    private static func statesThroughGuestStop(
        _ stream: AsyncStream<VMState>,
        timeout: Duration
    ) async throws -> [VMState] {
        try await withThrowingTaskGroup(of: [VMState].self) { group in
            group.addTask {
                var observed: [VMState] = []
                var sawRunning = false
                for await state in stream {
                    observed.append(state)
                    if state == .running {
                        sawRunning = true
                    }
                    if sawRunning, state == .stopped {
                        return observed
                    }
                }
                throw HarnessFailure.consoleEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HarnessFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw HarnessFailure.consoleEnded
            }
            return result
        }
    }

    private static func statesThroughTerminalState(
        _ stream: AsyncStream<VMState>,
        timeout: Duration
    ) async throws -> [VMState] {
        try await withThrowingTaskGroup(of: [VMState].self) { group in
            group.addTask {
                var observed: [VMState] = []
                var sawRunning = false
                for await state in stream {
                    observed.append(state)
                    if state == .running {
                        sawRunning = true
                    }
                    if sawRunning {
                        if state == .stopped {
                            return observed
                        }
                        if case .failed = state {
                            return observed
                        }
                    }
                }
                throw HarnessFailure.consoleEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HarnessFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw HarnessFailure.consoleEnded
            }
            return result
        }
    }

    static func observeGuestReboot(
        events: AsyncStream<HarnessEvent>,
        continuation: AsyncStream<HarnessEvent>.Continuation
    ) async throws -> (records: [TestGuestRecord], outcome: RebootObservation) {
        var records: [TestGuestRecord] = []
        var iterator = events.makeAsyncIterator()
        var didSeeRebootMarker = false
        var sawRunning = false
        var timeoutTask = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            continuation.yield(.rebootProbeTimedOut)
        }
        defer { timeoutTask.cancel() }

        while let event = await iterator.next() {
            switch event {
            case .record(let record):
                records.append(record)
                if case .check(name: "rng-reboot", result: .ok, detail: _) = record {
                    didSeeRebootMarker = true
                    timeoutTask.cancel()
                    timeoutTask = Task {
                        try? await Task.sleep(for: .seconds(15))
                        guard !Task.isCancelled else { return }
                        continuation.yield(.rebootProbeTimedOut)
                    }
                } else if didSeeRebootMarker, record == .bootOK {
                    return (records, .guestRestarted)
                } else if case .check(
                    name: let name,
                    result: .fail,
                    detail: let detail
                ) = record {
                    throw HarnessFailure.guestCheckFailed(name: name, detail: detail)
                } else if record == .done {
                    if didSeeRebootMarker {
                        return (records, .noRestartObserved)
                    }
                    throw HarnessFailure.guestFinishedBeforeRestartMarker
                }
            case .state(let state):
                if state == .running {
                    sawRunning = true
                } else if case .failed = state {
                    throw HarnessFailure.guestVMFailedDuringRebootObservation
                } else if sawRunning, state == .stopped {
                    if didSeeRebootMarker {
                        return (records, .guestDidStop)
                    }
                    throw HarnessFailure.guestStoppedBeforeRestartMarker
                }
            case .rebootProbeTimedOut:
                if didSeeRebootMarker {
                    return (records, .noRestartObserved)
                }
                throw HarnessFailure.timedOut
            case .consoleMarkerSeen:
                continue
            case .consoleStreamEnded:
                throw HarnessFailure.consoleEnded
            }
        }
        throw HarnessFailure.consoleEnded
    }

    private static func waitForConsoleMarker(
        _ marker: String,
        events: AsyncStream<HarnessEvent>,
        timeout: Duration,
        allowGuestDone: Bool = false,
        allowGuestTerminalState: Bool = false
    ) async throws {
        guard !marker.isEmpty else {
            throw HarnessFailure.consoleMarkerNotObserved(marker)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var sawRunning = false
                for await event in events {
                    switch event {
                    case .consoleMarkerSeen(let observedMarker) where observedMarker == marker:
                        return
                    case .consoleMarkerSeen:
                        continue
                    case .record(.done) where !allowGuestDone:
                        throw HarnessFailure.consoleMarkerNotObserved(marker)
                    case .record(.done):
                        continue
                    case .record(.check(name: let name, result: .fail, detail: let detail)):
                        throw HarnessFailure.guestCheckFailed(name: name, detail: detail)
                    case .consoleStreamEnded:
                        throw HarnessFailure.consoleMarkerNotObserved(marker)
                    case .record, .rebootProbeTimedOut:
                        continue
                    case .state(.running):
                        sawRunning = true
                    case .state(.stopped) where sawRunning && !allowGuestTerminalState:
                        throw HarnessFailure.consoleMarkerNotObserved(marker)
                    case .state(.failed) where sawRunning && !allowGuestTerminalState:
                        throw HarnessFailure.consoleMarkerNotObserved(marker)
                    case .state:
                        continue
                    }
                }
                throw HarnessFailure.consoleEnded
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HarnessFailure.timedOut
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw HarnessFailure.consoleEnded
            }
        }
    }

    static func consoleMarkerMatches(_ marker: Data, in buffer: Data) -> Bool {
        if buffer.range(of: marker) != nil {
            return true
        }
        guard marker.last == 0x0A, marker.dropLast().last != 0x0D else {
            return false
        }
        var crlfMarker = Data(marker.dropLast())
        crlfMarker.append(contentsOf: [0x0D, 0x0A])
        return buffer.range(of: crlfMarker) != nil
    }

    static func retainConsoleMarkerSearchTail(
        _ buffer: inout Data,
        maximumMarkerLength: Int
    ) {
        guard maximumMarkerLength > 0, buffer.count > maximumMarkerLength else { return }
        buffer = Data(buffer.suffix(maximumMarkerLength))
    }

    private static func collectRecords(
        _ stream: AsyncStream<TestGuestRecord>
    ) async -> [TestGuestRecord] {
        var observed: [TestGuestRecord] = []
        for await record in stream {
            observed.append(record)
        }
        return observed
    }

    private static func readConsoleLog(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw HarnessFailure.consoleLogMissing
        }
    }

    private static func readLatestBootLog(in directory: URL) throws -> Data {
        let bootLogs: [URL]
        do {
            bootLogs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent.hasPrefix("boot-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch {
            throw HarnessFailure.consoleLogMissing
        }
        guard let latestBootLog = bootLogs.first else {
            throw HarnessFailure.consoleLogMissing
        }
        do {
            return try Data(contentsOf: latestBootLog)
        } catch {
            throw HarnessFailure.consoleLogMissing
        }
    }

    private static func waitForConsoleTask(_ task: Task<Void, Never>) async {
        let didFinish = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }

            let didFinish = await group.next() ?? false
            if !didFinish {
                task.cancel()
            }
            group.cancelAll()
            return didFinish
        }
        if !didFinish {
            task.cancel()
        }
        await task.value
    }

    private static func attachConsole(
        _ snapshot: (bytes: Data, omittedByteCount: UInt64),
        parserOmittedByteCount: UInt64,
        tailOmittedByteCount: UInt64,
        to testCase: XCTestCase
    ) {
        var attachmentData = Data()
        if parserOmittedByteCount > 0 {
            attachmentData.append(
                Data("[\(parserOmittedByteCount) bytes omitted by the test-record console stream]\n".utf8)
            )
        }
        if tailOmittedByteCount > 0 {
            attachmentData.append(
                Data("[\(tailOmittedByteCount) bytes omitted by the tail-capture console stream]\n".utf8)
            )
        }
        if snapshot.omittedByteCount > 0 {
            attachmentData.append(
                Data("[\(snapshot.omittedByteCount) earlier captured console bytes omitted; showing the tail]\n".utf8)
            )
        }
        attachmentData.append(snapshot.bytes)
        let attachment = XCTAttachment(data: attachmentData, uniformTypeIdentifier: "public.plain-text")
        attachment.name = "Linux test guest hvc0 console"
        attachment.lifetime = .keepAlways
        testCase.add(attachment)
    }
}
