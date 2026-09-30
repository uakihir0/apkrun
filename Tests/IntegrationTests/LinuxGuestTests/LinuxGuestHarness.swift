import Darwin
import DiagnosticsCore
import Foundation
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

enum LinuxGuestHarness {
    enum StopBehavior: Equatable {
        case guestPowerOff
        case requestPowerButton
        case forced
    }

    struct RunResult {
        let records: [TestGuestRecord]
        let states: [VMState]
    }

    private enum HarnessFailure: Error {
        case missingArtifacts(String)
        case invalidArtifactDirectory(String)
        case timedOut
        case consoleEnded
        case startUnexpectedlySucceeded
        case unexpectedStartFailure
    }

    static func run(
        testCase: XCTestCase,
        stopBehavior: StopBehavior,
        powerOff: Bool
    ) async throws -> RunResult {
        let artifacts = try artifactURLs()
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-linux-guest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: runDirectory) }

        let definition = LinuxTestGuest.definition(
            kernel: artifacts.kernel,
            initrd: artifacts.initrd,
            powerOff: powerOff
        )
        let validated = try VMDefinitionValidator().validate(definition)
        let paths = APKRunPaths(
            allowingHomeOverride: true,
            environment: ["APKRUN_HOME": runDirectory.appending(path: "data").path]
        )
        let controller = VMController(
            definition: validated,
            diagnostics: DiagnosticsContext.live(paths: paths)
        )
        let console = controller.console(.systemConsole)
        let parserByteStream = console.makeByteStream()
        let tailCaptureByteStream = console.makeByteStream(
            bufferingPolicy: .preserveNewest
        )
        let records = AsyncStream.makeStream(
            of: TestGuestRecord.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        let consoleCapture = LinuxGuestConsoleCapture()
        let parserTask = Task {
            var parser = TestGuestLineParser()
            for await bytes in parserByteStream.stream {
                guard !Task.isCancelled else { break }
                for record in parser.consume(bytes) {
                    records.continuation.yield(record)
                }
            }
            if !Task.isCancelled {
                for record in parser.finish() {
                    records.continuation.yield(record)
                }
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
            }
            stateStream.continuation.finish()
        }

        do {
            try await controller.start()
            let observedRecords = try await recordsUntilDone(records.stream)
            switch stopBehavior {
            case .guestPowerOff:
                break
            case .requestPowerButton:
                try await controller.requestGuestStop()
            case .forced:
                try await controller.stop()
            }

            let stateTimeout: Duration =
                stopBehavior == .requestPowerButton ? .seconds(10) : .seconds(60)
            let observedStates = try await statesThroughGuestStop(
                stateStream.stream,
                timeout: stateTimeout
            )
            if stopBehavior == .requestPowerButton {
                XCTAssertEqual(
                    observedStates,
                    [.stopped, .starting, .running, .stopping, .stopped]
                )
            }
            await waitForConsoleTask(parserTask)
            await waitForConsoleTask(captureTask)
            stateTask.cancel()
            await stateTask.value
            attachConsole(
                consoleCapture.snapshot(),
                parserOmittedByteCount: parserByteStream.droppedByteCount,
                tailOmittedByteCount: tailCaptureByteStream.droppedByteCount,
                to: testCase
            )
            return RunResult(records: observedRecords, states: observedStates)
        } catch {
            await cleanup(controller)
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
            throw error
        }
    }

    private static func cleanup(_ controller: VMController) async {
        var state = await controller.state
        if state == .running || state == .paused || state == .stopping {
            try? await controller.stop()
            state = await controller.state
        }
        if case .failed = state {
            try? await controller.reset()
            state = await controller.state
        }
        if state != .stopped {
            FailedLinuxGuestControllerRetention.shared.retainUntilReleased(controller)
        }
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

    private static func artifactURLs() throws -> (kernel: URL, initrd: URL) {
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
        testCase.add(attachment)
    }
}
