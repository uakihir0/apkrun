import Darwin
import Foundation

/// The package selected from an APK and whether its metadata parser ran in the specified sandbox.
public struct DevelopmentAPKResolution: Equatable, Sendable {
    /// The package identifier reported by aapt2.
    public let packageIdentifier: String
    /// Whether sandbox-exec restricted the aapt2 process.
    public let wasSandboxed: Bool
}

/// Resolves the package name of an APK for `apkrun dev launch` (#026).
///
/// Android's PackageManager remains authoritative after installation. This host-side `aapt2` call only chooses which
/// package the development command asks the Guest Agent to launch.
public enum DevelopmentAPKResolver {
    /// Matches the package store's per-file APK transfer limit.
    static let maximumAPKSize: UInt64 = 2 * 1_024 * 1_024 * 1_024

    /// Parses only a staged copy of the APK when sandbox-exec is available.
    ///
    /// The source path is used to locate aapt2 through the SDK environment. aapt2 itself receives only a private
    /// temporary copy and a minimal locale environment.
    public static func resolve(
        in apkURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourcesDirectory: URL? = Bundle.main.resourceURL
    ) async throws(DevelopmentAPKFailure) -> DevelopmentAPKResolution {
        try await resolve(
            in: apkURL,
            environment: environment,
            resourcesDirectory: resourcesDirectory,
            sandboxExecutable: URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        )
    }

    static func resolve(
        in apkURL: URL,
        environment: [String: String],
        resourcesDirectory: URL?,
        sandboxExecutable: URL?
    ) async throws(DevelopmentAPKFailure) -> DevelopmentAPKResolution {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: apkURL.path) else {
            throw .apkNotFound
        }
        guard
            let attributes = try? fileManager.attributesOfItem(atPath: apkURL.path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else {
            throw .apkNotRegularFile
        }
        if let fileSize = attributes[.size] as? NSNumber, fileSize.uint64Value > maximumAPKSize {
            throw .apkTooLarge(limit: maximumAPKSize)
        }
        guard fileManager.isReadableFile(atPath: apkURL.path) else {
            throw .apkNotReadable
        }

        guard let aapt2 = resolveAapt2(environment: environment, resourcesDirectory: resourcesDirectory) else {
            throw .aapt2NotFound
        }
        let resolvedAapt2 = aapt2.resolvingSymlinksInPath()
        let result: DevelopmentAPKProcessResult
        let wasSandboxed: Bool
        if let sandboxExecutable, fileManager.isExecutableFile(atPath: sandboxExecutable.path) {
            let stagedAPK = try DevelopmentAPKStaging.create(
                from: apkURL,
                maximumSize: maximumAPKSize
            )
            defer { try? fileManager.removeItem(at: stagedAPK.directoryURL) }
            let arguments = try DevelopmentAPKSandbox.arguments(
                tool: resolvedAapt2,
                stagedAPK: stagedAPK.apkURL,
                stagingDirectory: stagedAPK.directoryURL
            )
            result = try await DevelopmentAPKProcess.run(
                executable: sandboxExecutable,
                arguments: arguments,
                environment: Self.toolEnvironment,
                timeout: .seconds(20),
                maximumOutputBytes: 16 * 1_024 * 1_024
            )
            wasSandboxed = true
        } else {
            result = try await DevelopmentAPKProcess.run(
                executable: resolvedAapt2,
                arguments: ["dump", "badging", apkURL.path],
                environment: Self.toolEnvironment,
                timeout: .seconds(20),
                maximumOutputBytes: 16 * 1_024 * 1_024
            )
            wasSandboxed = false
        }
        guard result.status == 0 else {
            throw .aapt2Failed(status: result.status)
        }
        return DevelopmentAPKResolution(
            packageIdentifier: try parsePackageIdentifier(
                from: String(decoding: result.standardOutput, as: UTF8.self)
            ),
            wasSandboxed: wasSandboxed
        )
    }

    private static let toolEnvironment = ["LANG": "C", "LC_ALL": "C"]

    /// Checks a package ID using Android's dot-separated package identifier grammar.
    public static func isValidPackageIdentifier(_ value: String) -> Bool {
        guard value.utf8.count <= 255 else {
            return false
        }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return components.count >= 2
            && components.allSatisfy { component in
                guard let first = component.first, first.isASCII, first.isLetter else {
                    return false
                }
                return component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            }
    }

    /// Parses the `package: name='…'` line emitted by `aapt2 dump badging`.
    static func parsePackageIdentifier(from output: String) throws(DevelopmentAPKFailure) -> String {
        var identifiers = Set<String>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "package:" else {
                continue
            }
            guard let nameField = fields.first(where: { $0.hasPrefix("name=") }) else {
                throw .packageIdentifierMissing
            }
            let quotedValue = nameField.dropFirst("name=".count)
            guard
                quotedValue.count >= 3,
                quotedValue.first == "'",
                quotedValue.last == "'"
            else {
                throw .packageIdentifierMissing
            }
            let identifier = String(quotedValue.dropFirst().dropLast())
            guard isValidPackageIdentifier(identifier) else {
                throw .invalidPackageIdentifier
            }
            identifiers.insert(identifier)
        }
        guard identifiers.count == 1, let identifier = identifiers.first else {
            throw .packageIdentifierMissing
        }
        return identifier
    }

    private static func resolveAapt2(
        environment: [String: String],
        resourcesDirectory: URL?
    ) -> URL? {
        let fileManager = FileManager.default
        if let resourcesDirectory {
            let bundledTool = resourcesDirectory.appendingPathComponent("tools/aapt2")
            if fileManager.isExecutableFile(atPath: bundledTool.path) {
                return bundledTool
            }
        }

        var visitedSDKs = Set<String>()
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            guard
                let sdkPath = environment[key],
                !sdkPath.isEmpty,
                visitedSDKs.insert(sdkPath).inserted
            else {
                continue
            }
            let buildTools = URL(fileURLWithPath: sdkPath, isDirectory: true)
                .appendingPathComponent("build-tools", isDirectory: true)
            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: buildTools,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }
            let versions = entries.filter { entry in
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
            }
            for version in versions {
                let candidate = version.appendingPathComponent("aapt2")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }
}

/// A failure while resolving an APK for the development-only launch command.
public enum DevelopmentAPKFailure: Error, Equatable, Sendable {
    /// The path does not exist.
    case apkNotFound
    /// The path does not refer to a regular file.
    case apkNotRegularFile
    /// The APK is not readable by this process.
    case apkNotReadable
    /// Neither the app's bundled `Resources/tools/aapt2` nor an SDK build-tools copy is available.
    case aapt2NotFound
    /// The aapt2 process could not be started.
    case aapt2LaunchFailed
    /// The aapt2 process exceeded its time limit.
    case aapt2TimedOut
    /// The combined aapt2 output exceeded the configured byte limit.
    case aapt2OutputTooLarge
    /// The APK could not be copied into its private inspection directory.
    case apkStagingFailed
    /// The APK exceeds the package store's per-file limit.
    case apkTooLarge(limit: UInt64)
    /// A safe sandbox profile could not be created for the aapt2 executable.
    case sandboxProfileFailed
    /// The aapt2 process exited unsuccessfully.
    case aapt2Failed(status: Int32)
    /// The output did not contain exactly one package name.
    case packageIdentifierMissing
    /// The package name in the output did not satisfy Android's package name grammar.
    case invalidPackageIdentifier
}

struct DevelopmentAPKStaging {
    let directoryURL: URL
    let apkURL: URL

    static func create(from sourceURL: URL, maximumSize: UInt64) throws(DevelopmentAPKFailure) -> Self {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("apkrun-apk-inspection-\(UUID().uuidString)", isDirectory: true)
        let stagedAPK = directory.appendingPathComponent("input.apk", isDirectory: false)
        let source: FileHandle
        do {
            source = try FileHandle(forReadingFrom: sourceURL)
        } catch {
            throw DevelopmentAPKFailure.apkStagingFailed
        }
        defer { try? source.close() }

        do {
            guard try source.seekToEnd() <= maximumSize else {
                throw DevelopmentAPKFailure.apkTooLarge(limit: maximumSize)
            }
            try source.seek(toOffset: 0)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard
                fileManager.createFile(
                    atPath: stagedAPK.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            else {
                throw DevelopmentAPKFailure.apkStagingFailed
            }
            let destination = try FileHandle(forWritingTo: stagedAPK)
            defer { try? destination.close() }
            var copiedBytes: UInt64 = 0
            while let chunk = try source.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                let (nextCopiedBytes, overflow) = copiedBytes.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow, nextCopiedBytes <= maximumSize else {
                    throw DevelopmentAPKFailure.apkTooLarge(limit: maximumSize)
                }
                try destination.write(contentsOf: chunk)
                copiedBytes = nextCopiedBytes
            }
            try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: stagedAPK.path)
            let resolvedDirectory = directory.resolvingSymlinksInPath()
            return Self(
                directoryURL: resolvedDirectory,
                apkURL: resolvedDirectory.appendingPathComponent(stagedAPK.lastPathComponent)
            )
        } catch let failure as DevelopmentAPKFailure {
            try? fileManager.removeItem(at: directory)
            throw failure
        } catch {
            try? fileManager.removeItem(at: directory)
            throw DevelopmentAPKFailure.apkStagingFailed
        }
    }
}

enum DevelopmentAPKSandbox {
    static func profile(
        tool: URL,
        stagedAPK: URL,
        stagingDirectory: URL
    ) throws(DevelopmentAPKFailure) -> String {
        guard
            let systemLibraryPath = sbplLiteral("/System/Library"),
            let unixLibraryPath = sbplLiteral("/usr/lib")
        else {
            throw .sandboxProfileFailed
        }
        var toolRules: [String] = []
        for path in sandboxPathVariants(tool.path) {
            guard let literal = sbplLiteral(path) else {
                throw DevelopmentAPKFailure.sandboxProfileFailed
            }
            toolRules.append("(allow process-exec (literal \(literal)))")
            toolRules.append("(allow file-map-executable (literal \(literal)))")
            toolRules.append("(allow file-read* (literal \(literal)))")
        }
        var stagedAPKRules: [String] = []
        for path in sandboxPathVariants(stagedAPK.path) {
            guard let literal = sbplLiteral(path) else {
                throw DevelopmentAPKFailure.sandboxProfileFailed
            }
            stagedAPKRules.append("(allow file-read* (literal \(literal)))")
        }
        var stagingDirectoryRules: [String] = []
        for path in sandboxPathVariants(stagingDirectory.path) {
            guard let literal = sbplLiteral(path) else {
                throw DevelopmentAPKFailure.sandboxProfileFailed
            }
            stagingDirectoryRules.append("(allow file-read* (subpath \(literal)))")
            stagingDirectoryRules.append(
                "(allow file-read-metadata file-test-existence (path-ancestors \(literal)))"
            )
        }
        return """
            (version 1)
            (import "dyld-support.sb")
            (deny default)
            (deny process-fork)
            (allow mach-bootstrap)
            (allow sysctl-read)
            \(toolRules.joined(separator: "\n"))
            \(stagedAPKRules.joined(separator: "\n"))
            \(stagingDirectoryRules.joined(separator: "\n"))
            (allow file-read* file-map-executable (subpath \(systemLibraryPath)))
            (allow file-read* file-map-executable (subpath \(unixLibraryPath)))
            (deny network*)
            (deny file-write*)
            """
    }

    static func arguments(tool: URL, stagedAPK: URL, stagingDirectory: URL) throws(DevelopmentAPKFailure) -> [String] {
        let profile = try profile(tool: tool, stagedAPK: stagedAPK, stagingDirectory: stagingDirectory)
        return ["-p", profile, tool.path, "dump", "badging", stagedAPK.path]
    }

    private static func sbplLiteral(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return "\""
            + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func sandboxPathVariants(_ path: String) -> [String] {
        if path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") {
            return [path, String(path.dropFirst("/private".count))]
        }
        if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
            return [path, "/private\(path)"]
        }
        return [path]
    }
}

struct DevelopmentAPKProcessResult: Sendable {
    var status: Int32
    var standardOutput: Data
}

/// A bounded subprocess runner dedicated to the small development APK-resolution path.
enum DevelopmentAPKProcess {
    fileprivate static let terminationGrace: Duration = .milliseconds(500)
    private static let readChunkSize = 16 * 1_024

    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        maximumOutputBytes: Int
    ) async throws(DevelopmentAPKFailure) -> DevelopmentAPKProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment.merging(["LANG": "C", "LC_ALL": "C"]) { _, fixed in fixed }
        process.standardInput = FileHandle.nullDevice
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        let state = DevelopmentAPKProcessState(process: process, maximumOutputBytes: maximumOutputBytes)

        let status: Int32? = await withCheckedContinuation {
            (continuation: CheckedContinuation<Int32?, Never>) in
            process.terminationHandler = { finished in
                state.markExited()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: nil)
                return
            }

            let outputTask = Self.readToEnd(standardOutput.fileHandleForReading, isError: false, state: state)
            let errorTask = Self.readToEnd(standardError.fileHandleForReading, isError: true, state: state)
            let timer = Task.detached {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled, state.terminateIfRunning(for: .timedOut) else {
                    return
                }
                try? await Task.sleep(for: terminationGrace)
                state.killIfRunning()
            }
            state.attach(output: outputTask, errorOutput: errorTask, timer: timer)
        }

        guard let status else {
            throw .aapt2LaunchFailed
        }
        let output = await state.collect()
        if state.didTimeOut {
            throw .aapt2TimedOut
        }
        if state.didExceedOutputLimit {
            throw .aapt2OutputTooLarge
        }
        return DevelopmentAPKProcessResult(status: status, standardOutput: output)
    }

    private static func readToEnd(
        _ handle: FileHandle,
        isError: Bool,
        state: DevelopmentAPKProcessState
    ) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    while true {
                        let chunk = handle.readData(ofLength: readChunkSize)
                        guard !chunk.isEmpty else {
                            continuation.resume()
                            return
                        }
                        state.append(chunk, isError: isError)
                    }
                }
            }
        }
    }
}

/// The timeout, output readers, and process exit share this lock-protected state.
private final class DevelopmentAPKProcessState: @unchecked Sendable {
    enum TerminationReason: Equatable {
        case timedOut
        case outputLimit
    }

    private let process: Process
    private let maximumOutputBytes: Int
    private let lock = NSLock()
    private var hasExited = false
    private var terminationReason: TerminationReason?
    private var exceededOutputLimit = false
    private var capturedByteCount = 0
    private var outputData = Data()
    private var timer: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    init(process: Process, maximumOutputBytes: Int) {
        self.process = process
        self.maximumOutputBytes = maximumOutputBytes
    }

    func attach(output: Task<Void, Never>, errorOutput: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.withLock {
            outputTask = output
            errorTask = errorOutput
            self.timer = timer
            if hasExited {
                timer.cancel()
            }
        }
    }

    func markExited() {
        lock.withLock {
            hasExited = true
            timer?.cancel()
        }
    }

    /// Retains stdout bytes up to the shared stdout/stderr cap.
    func append(_ data: Data, isError: Bool) {
        let exceedsLimit = lock.withLock {
            guard capturedByteCount + data.count <= maximumOutputBytes else {
                exceededOutputLimit = true
                return true
            }
            capturedByteCount += data.count
            if !isError {
                outputData.append(data)
            }
            return false
        }
        if exceedsLimit {
            if terminateIfRunning(for: .outputLimit) {
                Task.detached {
                    try? await Task.sleep(for: DevelopmentAPKProcess.terminationGrace)
                    self.killIfRunning()
                }
            }
        }
    }

    func terminateIfRunning(for reason: TerminationReason) -> Bool {
        lock.withLock {
            guard !hasExited, terminationReason == nil else {
                return false
            }
            terminationReason = reason
            switch reason {
            case .timedOut:
                break
            case .outputLimit:
                exceededOutputLimit = true
            }
            process.terminate()
            return true
        }
    }

    func killIfRunning() {
        lock.withLock {
            guard !hasExited else {
                return
            }
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    var didTimeOut: Bool {
        lock.withLock { terminationReason == .timedOut }
    }

    var didExceedOutputLimit: Bool {
        lock.withLock { exceededOutputLimit }
    }

    func collect() async -> Data {
        let (outputTask, errorTask) = lock.withLock { (outputTask, errorTask) }
        await outputTask?.value
        _ = await errorTask?.value
        return lock.withLock { outputData }
    }
}
