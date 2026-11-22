import ArgumentParser
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun diagnostics [--output <path>] [--include-logcat] [--package <id>]
/// [--deep] [--json]`: writes a diagnostics bundle (diagnostics.md §8).
struct DiagnosticsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics",
        abstract: "Write a diagnostics bundle (ZIP) with host and guest state."
    )

    @Option(name: .long, help: "Output ZIP path (default: ~/Desktop).")
    var output: String?

    @Flag(name: .long, help: "Keep every logcat line instead of the filtered subset.")
    var includeLogcat = false

    @Flag(name: .long, help: "Include deep checks and metrics.")
    var deep = false

    @Option(name: .long, help: "Focus the report on one package ID.")
    var package: String?

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        let url = Self.outputURL(output)
        // The bundle holds sensitive state: 0600 per §8.4.
        FileManager.default.createFile(
            atPath: url.path, contents: nil,
            attributes: [.posixPermissions: 0o600])
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Output.writeLogLine("Cannot write to \(url.path)", toStandardError: true)
            throw ExitCode(1)
        }
        defer { try? handle.close() }
        do {
            try await daemonReport(to: handle)
            try emitOK(path: url.path, mode: "full")
        } catch let code as ExitCode {
            try? FileManager.default.removeItem(at: url)
            throw code
        } catch {
            // apkrund down → host-only bundle, still one ZIP (§8.4).
            do {
                try await hostOnlyReport(to: handle)
                try emitOK(path: url.path, mode: "hostOnly")
            } catch {
                try? FileManager.default.removeItem(at: url)
                Output.writeLogLine(
                    "Could not write the report: \(error.localizedDescription)",
                    toStandardError: true)
                throw ExitCode(1)
            }
        }
    }

    /// The daemon-side report through `createDiagnostics` (§8.1).
    private func daemonReport(to handle: FileHandle) async throws {
        let client = try RuntimeControlClient(clientKind: .cli)
        let request = DiagnosticsRequest(
            includeLogcat: includeLogcat,
            deep: deep,
            focusPackage: package,
            createdBy: "cli")
        let operation = try await client.createDiagnostics(request, output: handle)
        let snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
            using: client,
            operationID: operation.operationID,
            progressToStderr: false)
        try OperationCommandOutput.requireSuccess(snapshot)
    }

    /// The host-only report when apkrund cannot be reached (§8.4).
    private func hostOnlyReport(to handle: FileHandle) async throws {
        let paths = APKRunPaths(
            allowingHomeOverride: true,
            environment: ProcessInfo.processInfo.environment)
        let options = DiagnosticsOptions(
            includeLogcat: includeLogcat,
            deep: deep,
            focusPackage: package,
            createdBy: "cli",
            mode: "hostOnly")
        let identity = RedactionIdentity(
            preservedPaths: [paths.dataRoot.path, paths.logsRoot.path])
        let contributors: [DiagnosticsContributor] = [
            HostEnvironmentContributor(),
            VersionsContributor(versions: { [
                "apkrund": "unavailable",
                "cli": Output.versionHuman(BuildInfo.current),
                "apiLevel": "\(APIVersion.current.major).\(APIVersion.current.minor)",
            ] }),
            ConfigContributor(settingsFile: paths.settingsFile),
            HostLogsContributor(mirrorDirectory: paths.logsRoot),
            PerfContributor(
                launchesFile: paths.launchPerformanceFile,
                bootsFile: paths.bootPerformanceFile),
        ]
        let service = DiagnosticsBundleService(
            identity: identity, contributors: contributors,
            build: Output.versionHuman(BuildInfo.current))
        let result = try await service.run(
            options: options,
            to: handle,
            summaryContext: { _ in
                DiagnosticsSummaryContext(
                    statusLine: "APKRun's background service isn't running.",
                    buildLine: Output.versionHuman(BuildInfo.current),
                    guestMissingReason: "APKRun's background service isn't running",
                    operationID: "")
            })
        if !result.omitted.isEmpty {
            Output.write(
                "Omitted: "
                    + result.omitted.map { "\($0.item) (\($0.reason))" }.joined(separator: ", "))
        }
    }

    /// Prints the result line.
    private func emitOK(path: String, mode: String) throws {
        if json {
            Output.write("{\"path\": \"\(path)\", \"mode\": \"\(mode)\"}")
        } else {
            Output.write(
                mode == "hostOnly"
                    ? "Wrote the host-only report to \(path)"
                    : "Wrote the report to \(path)")
        }
    }

    /// The default save path: `~/Desktop/APKRun-Diagnostics-<stamp>.zip`
    /// (§8.4).
    static func outputURL(_ option: String?) -> URL {
        if let option, !option.isEmpty {
            return URL(fileURLWithPath: (option as NSString).expandingTildeInPath)
        }
        let stamp: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.string(from: Date())
        }()
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        return desktop.appendingPathComponent(
            "APKRun-Diagnostics-\(stamp).zip")
    }
}
