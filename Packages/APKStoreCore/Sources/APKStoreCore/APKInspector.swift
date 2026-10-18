import Darwin
import DiagnosticsCore
import Foundation

/// The host-side facts read from one APK. Android remains the source of truth after install.
public struct APKFacts: Sendable, Equatable {
    /// The package name declared by the APK.
    public var packageID: PackageID
    /// Android's combined `longVersionCode`.
    public var versionCode: VersionCode
    /// The optional display version declared by the APK.
    public var versionName: String?
    /// The split name, or `nil` for a base APK.
    public var splitName: String?
    /// The best label available from the APK.
    public var displayName: String
    /// The minimum Android API level required by the APK.
    public var minSDK: Int
    /// The target Android API level declared by the APK.
    public var targetSDK: Int
    /// Native ABIs declared by the APK.
    public var nativeABIs: [String]

    /// Creates a snapshot of the host-inspected APK metadata.
    public init(
        packageID: PackageID,
        versionCode: VersionCode,
        versionName: String?,
        splitName: String?,
        displayName: String,
        minSDK: Int,
        targetSDK: Int,
        nativeABIs: [String]
    ) {
        self.packageID = packageID
        self.versionCode = versionCode
        self.versionName = versionName
        self.splitName = splitName
        self.displayName = displayName
        self.minSDK = minSDK
        self.targetSDK = targetSDK
        self.nativeABIs = nativeABIs
    }
}

/// Failures while inspecting a staged APK.
public enum APKInspectionFailure: Error, Equatable, Sendable {
    case inputNotReadable
    case aapt2NotFound
    case aapt2LaunchFailed
    case aapt2TimedOut
    case aapt2OutputTooLarge
    case aapt2Failed(Int32)
    case packageMetadataMissing
    case invalidPackageID
    case invalidVersionCode
    case invalidSDKValue
    case invalidSplitSet
    case io
}

/// Reads package metadata from a staged APK using aapt2.
///
/// Only APKs already copied into the private package import directory are passed to aapt2. When
/// `sandbox-exec` is available, the process cannot fork, access the network, or write to disk.
public struct APKInspector: Sendable {
    private let executable: URL?
    private let sandboxExecutable: URL?

    /// Creates an inspector using a bundled tool or the debug development tool path.
    public init(
        executable: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourcesDirectory: URL? = Bundle.main.resourceURL,
        sandboxExecutable: URL? = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    ) {
        if let executable {
            self.executable = executable
        } else if let bundled = Self.bundledAapt2(resourcesDirectory: resourcesDirectory) {
            self.executable = bundled
        } else {
            #if DEBUG
                self.executable = Self.resolveDevelopmentAapt2(environment: environment)
            #else
                self.executable = nil
            #endif
        }
        self.sandboxExecutable = sandboxExecutable
    }

    /// Runs aapt2 against one staged APK and parses the stable badging fields needed for installation.
    public func inspect(_ apk: URL) async throws(APKInspectionFailure) -> APKFacts {
        guard apk.isFileURL,
            let values = try? apk.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            (values.fileSize ?? 0) > 0
        else {
            throw .inputNotReadable
        }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw .aapt2NotFound
        }

        let process = Process()
        let wasSandboxed =
            sandboxExecutable.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false
        if !wasSandboxed {
            APKLogger(category: StoreLogCategory.`import`).warning(
                "aapt2 is running without the sandbox-exec profile",
                errorCode: "store.aapt2Unsandboxed"
            )
        }
        process.executableURL = wasSandboxed ? sandboxExecutable : executable
        if wasSandboxed {
            process.arguments = [
                "-p",
                Self.sandboxProfile(
                    tool: executable,
                    apk: apk,
                    importDirectory: apk.deletingLastPathComponent()
                ),
                executable.path,
                "dump",
                "badging",
                apk.path,
            ]
        } else {
            process.arguments = ["dump", "badging", apk.path]
        }
        process.environment = ["LANG": "C", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        do {
            try process.run()
        } catch {
            throw .aapt2LaunchFailed
        }
        try? outputPipe.fileHandleForWriting.close()
        let capturedOutput = BoundedOutput(limit: 16 * 1_024 * 1_024)
        let outputReader = Task.detached(priority: .utility) {
            try await Self.captureOutput(from: outputPipe.fileHandleForReading, into: capturedOutput)
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while process.isRunning,
            ContinuousClock.now < deadline,
            !(await capturedOutput.didExceedLimit)
        {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let outputTooLarge = await capturedOutput.didExceedLimit
        let timedOut = process.isRunning && !outputTooLarge
        if process.isRunning {
            process.terminate()
            let terminationDeadline = ContinuousClock.now + .milliseconds(500)
            while process.isRunning, ContinuousClock.now < terminationDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        try? outputPipe.fileHandleForReading.close()
        let outputData: Data
        do {
            outputData = try await outputReader.value
        } catch {
            throw .io
        }

        if timedOut {
            throw .aapt2TimedOut
        }
        if outputTooLarge {
            throw .aapt2OutputTooLarge
        }
        guard let output = String(data: outputData, encoding: .utf8) else {
            throw .aapt2OutputTooLarge
        }
        guard process.terminationStatus == 0 else {
            throw .aapt2Failed(process.terminationStatus)
        }
        return try Self.parseBadging(output)
    }

    /// Parses fields from `aapt2 dump badging`. Kept pure for fast parser tests.
    public static func parseBadging(_ output: String) throws(APKInspectionFailure) -> APKFacts {
        var packageFields: [String: String]?
        var label: String?
        var minSDK: Int?
        var targetSDK: Int?
        var nativeABIs: [String] = []

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("package:") {
                guard packageFields == nil else {
                    throw .packageMetadataMissing
                }
                packageFields = keyValueFields(in: String(line.dropFirst("package:".count)))
            } else if line.hasPrefix("application-label:'") {
                label = quotedValue(after: "application-label:", in: line)
            } else if line.hasPrefix("sdkVersion:'") {
                minSDK = integerValue(after: "sdkVersion:", in: line)
            } else if line.hasPrefix("targetSdkVersion:'") {
                targetSDK = integerValue(after: "targetSdkVersion:", in: line)
            } else if line.hasPrefix("native-code:") {
                nativeABIs = quotedValues(in: line)
            }
        }
        guard let fields = packageFields, let rawPackage = fields["name"] else {
            throw .packageMetadataMissing
        }
        guard let packageID = PackageID(rawValue: rawPackage) else {
            throw .invalidPackageID
        }
        guard let rawVersion = fields["versionCode"], let lowVersion = UInt32(rawVersion) else {
            throw .invalidVersionCode
        }
        let majorVersion: UInt32
        if let rawMajor = fields["versionCodeMajor"] {
            guard let parsed = UInt32(rawMajor) else {
                throw .invalidVersionCode
            }
            majorVersion = parsed
        } else {
            majorVersion = 0
        }
        let versionBits = (UInt64(majorVersion) << 32) | UInt64(lowVersion)
        guard versionBits <= UInt64(Int64.max) else {
            throw .invalidVersionCode
        }
        guard let minSDK, let targetSDK, minSDK >= 0, targetSDK >= 0 else {
            throw .invalidSDKValue
        }
        let split = fields["split"].flatMap { $0.isEmpty ? nil : $0 }
        let name = (label?.isEmpty == false ? label : nil) ?? packageID.rawValue
        return APKFacts(
            packageID: packageID,
            versionCode: VersionCode(versionBits),
            versionName: fields["versionName"],
            splitName: split,
            displayName: name,
            minSDK: minSDK,
            targetSDK: targetSDK,
            nativeABIs: nativeABIs.sorted()
        )
    }

    private actor BoundedOutput {
        private let limit: Int
        private var data = Data()
        private(set) var didExceedLimit = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) -> Bool {
            guard !didExceedLimit else { return false }
            guard data.count + chunk.count <= limit else {
                didExceedLimit = true
                return false
            }
            data.append(chunk)
            return true
        }

        func result() -> Data {
            data
        }
    }

    private static func captureOutput(from handle: FileHandle, into output: BoundedOutput) async throws -> Data {
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            guard await output.append(chunk) else { break }
        }
        return await output.result()
    }

    private static func bundledAapt2(resourcesDirectory: URL?) -> URL? {
        guard let resourcesDirectory else { return nil }
        let bundled = resourcesDirectory.appendingPathComponent("tools/aapt2")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }

    private static func resolveDevelopmentAapt2(environment: [String: String]) -> URL? {
        let fileManager = FileManager.default
        var visited = Set<String>()
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            guard let path = environment[key], !path.isEmpty, visited.insert(path).inserted else {
                continue
            }
            let buildTools = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("build-tools", isDirectory: true)
            let versions =
                (try? fileManager.contentsOfDirectory(
                    at: buildTools,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ))?
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending
                } ?? []
            for version in versions {
                let candidate = version.appendingPathComponent("aapt2")
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("aapt2")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func sandboxProfile(tool: URL, apk: URL, importDirectory: URL) -> String {
        let toolRules = sandboxPathVariants(tool.path).map { path in
            """
            (allow process-exec (literal \(sbpl(path))))
            (allow file-map-executable (literal \(sbpl(path))))
            (allow file-read* (literal \(sbpl(path))))
            """
        }.joined(separator: "\n")
        let apkRules = sandboxPathVariants(apk.path).map { "(allow file-read* (literal \(sbpl($0))))" }
            .joined(separator: "\n")
        let dirRules = sandboxPathVariants(importDirectory.path).map { path in
            """
            (allow file-read* (subpath \(sbpl(path))))
            (allow file-read-metadata file-test-existence (path-ancestors \(sbpl(path))))
            """
        }.joined(separator: "\n")
        return """
            (version 1)
            (import "dyld-support.sb")
            (deny default)
            (deny process-fork)
            (allow mach-bootstrap)
            (allow sysctl-read)
            \(toolRules)
            \(apkRules)
            \(dirRules)
            (allow file-read* file-map-executable (subpath "/System/Library"))
            (allow file-read* file-map-executable (subpath "/usr/lib"))
            (deny network*)
            """
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

    private static func sbpl(_ path: String) -> String {
        "\""
            + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func keyValueFields(in line: String) -> [String: String] {
        let pattern = #"([A-Za-z][A-Za-z0-9]*)='([^']*)'"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var fields: [String: String] = [:]
        for match in expression.matches(in: line, range: range) where match.numberOfRanges == 3 {
            guard let keyRange = Range(match.range(at: 1), in: line),
                let valueRange = Range(match.range(at: 2), in: line)
            else {
                continue
            }
            fields[String(line[keyRange])] = String(line[valueRange])
        }
        return fields
    }

    private static func quotedValue(after key: String, in line: String) -> String? {
        guard let start = line.range(of: key)?.upperBound,
            let quoteStart = line[start...].firstIndex(of: "'"),
            let quoteEnd = line[line.index(after: quoteStart)...].firstIndex(of: "'")
        else {
            return nil
        }
        return String(line[line.index(after: quoteStart)..<quoteEnd])
    }

    private static func quotedValues(in line: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"'([^']*)'"#) else { return [] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return expression.matches(in: line, range: range).compactMap { match in
            guard match.numberOfRanges == 2,
                let valueRange = Range(match.range(at: 1), in: line)
            else {
                return nil
            }
            return String(line[valueRange])
        }
    }

    private static func integerValue(after key: String, in line: String) -> Int? {
        quotedValue(after: key, in: line).flatMap(Int.init)
    }
}
