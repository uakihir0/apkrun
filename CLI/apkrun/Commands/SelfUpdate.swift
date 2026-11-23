import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun self-update`, the APKRun updater commands (cli.md §4.7).
struct SelfUpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "self-update",
        abstract: "Check for, install, and finish APKRun updates.",
        subcommands: [
            SelfUpdateCheckCommand.self,
            SelfUpdateInstallCommand.self,
            SelfUpdateFinishCommand.self,
        ]
    )
}

/// `apkrun self-update check [--json]` (§4.7). Exit 0 whether or not an
/// update is available; exit 69 when apkrund is unreachable.
struct SelfUpdateCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check the appcast for an APKRun update now."
    )

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        let status: SelfUpdateStatus
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            status = try await client.checkSelfUpdate(userInitiated: true)
        } catch {
            Output.writeLogLine("Open APKRun to check for updates.", toStandardError: true)
            throw ExitCode(69)
        }
        if json {
            try PackageQueryOutput.writeJSON(SelfUpdateCheckOutput(status: status))
            return
        }
        if let latest = status.latest {
            Output.write(
                "APKRun \(latest.version) is available (you have "
                    + "\(status.currentVersion)). Open APKRun to install it.")
        } else {
            Output.write("APKRun is up to date.")
        }
    }
}

/// The `--json` payload of `self-update check` (§4.7: `available` is the key).
private struct SelfUpdateCheckOutput: Codable {
    var available: Bool
    var currentVersion: String
    var currentBuild: Int
    var latest: AvailableRelease?
    var critical: Bool
    var lastCheckedAt: Date?
    var lastError: String?

    init(status: SelfUpdateStatus) {
        available = status.latest != nil
        currentVersion = status.currentVersion
        currentBuild = status.currentBuild
        latest = status.latest
        critical = status.critical
        lastCheckedAt = status.lastCheckedAt
        lastError = status.lastError?.code
    }
}

/// `apkrun self-update install` (§4.7): opens APKRun's update UI and does not
/// wait for the install to finish.
struct SelfUpdateInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Open APKRun to install the available update."
    )

    mutating func run() async throws {
        guard let url = URL(string: "apkrun://settings/general") else {
            throw CLIFailure.invalidArgument(argument: "url", reason: "invalid")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try? process.run()
        Output.write("Opened APKRun. Install the update there.")
    }
}

/// `apkrun self-update finish [--yes]` (§4.7): completes a pending restart
/// after the bundle was replaced.
struct SelfUpdateFinishCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finish",
        abstract: "Restart APKRun to finish the pending update."
    )

    @Flag(name: .long, help: "Restart without asking.")
    var yes = false

    mutating func run() async throws {
        let maintenance: MaintenanceControlClient
        do {
            maintenance = try MaintenanceControlClient(clientKind: .cli)
        } catch {
            Output.writeLogLine("Open APKRun to finish the update.", toStandardError: true)
            throw ExitCode(69)
        }
        let status = try await maintenance.status()
        guard case .restartPending = status.hostState else {
            Output.write("Nothing to finish.")
            return
        }
        let count = status.sessions.count + status.backgroundTasks.count
        if !yes, count > 0 {
            Output.write("\(count) app\(count == 1 ? "" : "s") will close. Continue? [y/N] ")
            guard let answer = readLine(), answer.lowercased() == "y" else {
                throw CLIFailure.declined
            }
        }
        _ = try await maintenance.restartForUpdate(closeSessions: true)
        Output.write("Restarting APKRun to finish the update.")
    }
}
