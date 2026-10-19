import Darwin
import DiagnosticsCore
import Foundation
import RuntimeCore

/// The outcome of the best-effort recovery work after an unclean daemon exit.
public struct DaemonUncleanExitRecoveryResult: Equatable, Sendable {
    /// The newest report recorded in the diagnostics index, when one was found.
    public let indexedCrashReport: URL?
    /// The number of stale APKRun ADB forwards successfully removed.
    public let removedADBForwards: Int
    /// Recovery steps that could not be completed.
    public let issues: [Issue]

    /// One non-fatal recovery issue.
    public enum Issue: String, Equatable, Sendable {
        /// The DiagnosticReports directory could not be read.
        case diagnosticReportsUnreadable
        /// The report path could not be recorded in the diagnostics index.
        case diagnosticsIndexUnavailable
        /// A Debug build could not resolve the adb executable.
        case adbExecutableUnavailable
        /// `adb forward --list` failed.
        case adbForwardListFailed
        /// One or more `adb forward --remove` commands failed.
        case adbForwardRemovalFailed
        /// `adb disconnect 127.0.0.1:6520` failed.
        case adbDisconnectFailed
    }

    /// Creates a recovery result.
    public init(indexedCrashReport: URL?, removedADBForwards: Int, issues: [Issue]) {
        self.indexedCrashReport = indexedCrashReport
        self.removedADBForwards = removedADBForwards
        self.issues = issues
    }
}

/// Runs the unclean-exit recovery steps without making them fatal to daemon startup.
public protocol DaemonUncleanExitRecovering: Sendable {
    /// Records the latest daemon crash report and clears Debug ADB state.
    func recover() async -> DaemonUncleanExitRecoveryResult
}

/// Finds and indexes the latest daemon crash report, then cleans Debug-only ADB state.
///
/// The report directory, index store, executable, and ADB process runner are dependencies so
/// recovery can be tested with a temporary directory and an in-memory command runner.
public struct DaemonUncleanExitRecovery: DaemonUncleanExitRecovering, Sendable {
    /// The result of running one ADB command.
    public struct ADBCommandResult: Equatable, Sendable {
        /// The process exit status, or `nil` when the process could not be launched.
        public let status: Int32?
        /// Standard output.
        public let output: String

        /// Creates a command result.
        public init(status: Int32?, output: String = "") {
            self.status = status
            self.output = output
        }
    }

    /// Runs one ADB command. Tests inject this to avoid starting external processes.
    public typealias ADBCommandRunner = @Sendable (URL, [String], Duration) async -> ADBCommandResult

    private static let adbCommandTimeout: Duration = .seconds(3)
    private static let diagnosticReportPrefix = "apkrund-"
    private static let staleForwardPrefix = "localabstract:apkrun-"

    private let diagnosticReportsDirectory: URL
    private let diagnosticsIndex: DiagnosticsIndexStore
    private let isDebugBuild: Bool
    private let adbExecutable: URL?
    private let runADBCommand: ADBCommandRunner

    /// Creates recovery with caller-supplied filesystem and process dependencies.
    public init(
        diagnosticReportsDirectory: URL,
        diagnosticsIndex: DiagnosticsIndexStore,
        configuration: BuildConfiguration,
        adbExecutable: URL?,
        commandRunner: @escaping ADBCommandRunner
    ) {
        self.diagnosticReportsDirectory = diagnosticReportsDirectory
        self.diagnosticsIndex = diagnosticsIndex
        isDebugBuild = configuration == .debug
        self.adbExecutable = adbExecutable
        runADBCommand = commandRunner
    }

    /// Creates recovery dependencies for the current daemon installation.
    public static func live(
        paths: APKRunPaths,
        buildInfo: BuildInfo,
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let isDebugBuild = buildInfo.configuration == .debug
        let adbExecutable =
            isDebugBuild
            ? try? AdbClient.resolveExecutable(environment: environment)
            : nil
        let reportDirectory =
            homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("DiagnosticReports", isDirectory: true)
        return Self(
            diagnosticReportsDirectory: reportDirectory,
            diagnosticsIndex: DiagnosticsIndexStore(fileURL: paths.diagnosticsIndexFile),
            configuration: buildInfo.configuration,
            adbExecutable: adbExecutable,
            commandRunner: Self.runADBProcess
        )
    }

    /// Performs recovery. Any individual failure is returned as a warning and does not throw.
    public func recover() async -> DaemonUncleanExitRecoveryResult {
        var issues: [DaemonUncleanExitRecoveryResult.Issue] = []
        var indexedCrashReport: URL?
        var removedADBForwards = 0

        do {
            if let report = try latestCrashReport() {
                do {
                    try diagnosticsIndex.recordDaemonCrashReport(at: report)
                    indexedCrashReport = report
                } catch {
                    issues.append(.diagnosticsIndexUnavailable)
                }
            }
        } catch {
            issues.append(.diagnosticReportsUnreadable)
        }

        if isDebugBuild {
            guard let adbExecutable else {
                issues.append(.adbExecutableUnavailable)
                return DaemonUncleanExitRecoveryResult(
                    indexedCrashReport: indexedCrashReport,
                    removedADBForwards: removedADBForwards,
                    issues: issues
                )
            }

            let forwardList = await runADBCommand(
                adbExecutable,
                ["-s", AdbClient.developmentEndpoint, "forward", "--list"],
                Self.adbCommandTimeout
            )
            if forwardList.status == 0 {
                var removedPorts = Set<UInt16>()
                var removalFailed = false
                for port in Self.staleForwardPorts(
                    from: forwardList.output,
                    serial: AdbClient.developmentEndpoint
                )
                where removedPorts.insert(port).inserted {
                    let result = await runADBCommand(
                        adbExecutable,
                        [
                            "-s",
                            AdbClient.developmentEndpoint,
                            "forward",
                            "--remove",
                            "tcp:\(port)",
                        ],
                        Self.adbCommandTimeout
                    )
                    if result.status == 0 {
                        removedADBForwards += 1
                    } else {
                        removalFailed = true
                    }
                }
                if removalFailed {
                    issues.append(.adbForwardRemovalFailed)
                }
            } else {
                issues.append(.adbForwardListFailed)
            }

            let disconnect = await runADBCommand(
                adbExecutable,
                ["disconnect", AdbClient.developmentEndpoint],
                Self.adbCommandTimeout
            )
            if disconnect.status != 0 {
                issues.append(.adbDisconnectFailed)
            }
        }

        return DaemonUncleanExitRecoveryResult(
            indexedCrashReport: indexedCrashReport,
            removedADBForwards: removedADBForwards,
            issues: issues
        )
    }

    private func latestCrashReport() throws -> URL? {
        guard FileManager.default.fileExists(atPath: diagnosticReportsDirectory.path) else {
            return nil
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: diagnosticReportsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let reports = urls.compactMap { url -> (URL, Date)? in
            guard url.lastPathComponent.hasPrefix(Self.diagnosticReportPrefix),
                url.pathExtension == "ips",
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
                ),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else {
                return nil
            }
            return (url, values.contentModificationDate ?? .distantPast)
        }
        return reports.max { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }
            return lhs.0.lastPathComponent < rhs.0.lastPathComponent
        }?.0
    }

    private static func staleForwardPorts(from output: String, serial: String) -> [UInt16] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3,
                fields[0] == serial,
                fields[2].hasPrefix(staleForwardPrefix),
                fields[1].hasPrefix("tcp:"),
                let port = UInt16(fields[1].dropFirst("tcp:".count)),
                port > 0
            else {
                return nil
            }
            return port
        }
    }

    private static func runADBProcess(
        executable: URL,
        arguments: [String],
        timeout: Duration
    ) async -> ADBCommandResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let outputReader = Task.detached {
                outputPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let errorReader = Task.detached {
                errorPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let processState = ADBRecoveryProcessState(process: process)
            let completion = ADBRecoveryCommandCompletion()
            process.terminationHandler = { finished in
                processState.markExited()
                Task {
                    let output = await outputReader.value
                    _ = await errorReader.value
                    guard completion.claim() else { return }
                    continuation.resume(
                        returning: ADBCommandResult(
                            status: finished.terminationStatus,
                            output: String(decoding: output, as: UTF8.self)
                        )
                    )
                }
            }

            do {
                try process.run()
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
            } catch {
                processState.markExited()
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
                Task {
                    _ = await outputReader.value
                    _ = await errorReader.value
                    guard completion.claim() else { return }
                    continuation.resume(returning: ADBCommandResult(status: nil))
                }
                return
            }

            Task.detached {
                try? await Task.sleep(for: timeout)
                guard processState.terminateIfRunning() else { return }
                try? await Task.sleep(for: .seconds(1))
                processState.killIfRunning()
            }
        }
    }
}

private final class ADBRecoveryCommandCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}

private final class ADBRecoveryProcessState: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var exited = false

    init(process: Process) {
        self.process = process
    }

    func markExited() {
        lock.withLock {
            exited = true
        }
    }

    func terminateIfRunning() -> Bool {
        lock.withLock {
            guard !exited, process.isRunning else { return false }
            process.terminate()
            return true
        }
    }

    func killIfRunning() {
        lock.withLock {
            guard !exited, process.isRunning else { return }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
