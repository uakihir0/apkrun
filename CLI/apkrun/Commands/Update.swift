import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun update` (cli.md §4.3): group command. The positional `<package>`
/// and the check flags live on the hidden `check` default subcommand: a
/// positional on this level would swallow the subcommand names.
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for, list, and manage Android app updates.",
        discussion: """
            `apkrun update [<package>] [--file <file> …] [--check-only] [--now] \
            [--json]` checks managed packages for updates and installs them; \
            see `apkrun help update check`.
            """,
        subcommands: [
            UpdateCheckCommand.self,
            UpdatePolicyCommand.self, UpdateAuthorityCommand.self, UpdateHistoryCommand.self,
            UpdateSkipCommand.self, UpdateUnskipCommand.self,
        ],
        defaultSubcommand: UpdateCheckCommand.self
    )
}

/// `apkrun update [<package>]` (cli.md §4.3): checks managed packages for
/// updates and prints one line per package. Exit code is 2 when any package
/// failed.
struct UpdateCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Check managed packages for updates.",
        shouldDisplay: false
    )

    @Argument(help: "The Android package name. Omit it to check every package.")
    var package: String?

    @Option(name: .long, parsing: .upToNextOption, help: "APK files for a manual update.")
    var file: [String] = []

    @Flag(name: .long, help: "Report only; do not download or notify.")
    var checkOnly = false

    @Flag(name: .long, help: "End the running app and install now (§7.3 Update Now).")
    var now = false

    @Flag(name: .long, help: "Print the results as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            if let package {
                guard !checkOnly else {
                    throw CLIFailure.invalidArgument(
                        argument: "--check-only", reason: "incompatible")
                }
                try await runSingle(client: client, package: package)
                return
            }
            guard file.isEmpty else {
                throw CLIFailure.invalidArgument(
                    argument: "--file", reason: "requiresPackage")
            }
            let (_, results) = try await client.checkForUpdates(
                packages: nil, checkOnly: checkOnly)
            if json {
                try PackageQueryOutput.writeJSON(results)
            } else {
                for result in results {
                    Output.write(UpdateOutput.line(result))
                }
            }
            let failures = results.filter {
                if case .failed = $0.outcome { return true }
                return false
            }
            if !failures.isEmpty {
                throw ExitCode(2)
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch let code as ExitCode {
            throw code
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }

    /// `apkrun update <package> [--file <apk>…]` (cli.md §4.3): check and
    /// install this package now; `--file` applies a manual file update.
    private func runSingle(client: RuntimeControlClient, package: String) async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        var files: [RuntimeImportSourceFile]?
        var handles: [FileHandle] = []
        if !self.file.isEmpty {
            guard self.file.count <= 20 else {
                throw CLIFailure.invalidArgument(
                    argument: "--file", reason: "invalidValue")
            }
            files = self.file.enumerated().map { index, path in
                RuntimeImportSourceFile(
                    fileIndex: index, name: URL(fileURLWithPath: path).lastPathComponent)
            }
            for path in self.file {
                let url = URL(fileURLWithPath: path)
                do {
                    handles.append(try FileHandle(forReadingFrom: url))
                } catch {
                    throw CLIFailure.fileNotAccessible(file: path, .permissionDenied)
                }
            }
        }
        defer {
            for handle in handles {
                try? handle.close()
            }
        }
        let options = UpdateNowOptions(closeRunningApp: now, files: files)
        let (_, outcome) = try await client.updatePackage(
            packageID: packageID, options: options, files: handles)
        if json {
            try PackageQueryOutput.writeJSON(outcome)
            return
        }
        guard let outcome else {
            Output.write("will update when \(package) quits")
            return
        }
        switch outcome {
        case .updated(let from, let to):
            Output.write("\(package): installed: \(from) → \(to)")
        case .rolledBack(let reason):
            Output.write("\(package): rolled back: \(reason)")
        case .keptAfterFailedHealthCheck(let reason):
            Output.write("\(package): kept after failed health check: \(reason)")
        case .skipped(let reason, let error):
            Output.write("\(package): skipped: \(reason)\(error.map { " (\($0.code))" } ?? "")")
            if error != nil {
                throw ExitCode(2)
            }
        }
    }
}

/// `apkrun update authority <package> <apkrun|manual|external>` (cli.md
/// §4.3, update-system.md §2.1): moves a package to a different update
/// authority. `googlePlay` is not user-settable (#98 only).
struct UpdateAuthorityCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "authority",
        abstract: "Set the update authority of an Android app."
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Argument(help: "apkrun, manual, or external.")
    var authority: String

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        guard let choice = AuthorityChoice(rawValue: authority), choice != .googlePlay else {
            throw CLIFailure.invalidArgument(argument: "authority", reason: "invalidValue")
        }
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.setUpdateAuthority(
                packageID: packageID, authority: choice)
            Output.write("\(status.packageID.rawValue): authority \(status.authority)")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun update policy <package>` (cli.md §4.3): sets the update mode and
/// provider of a managed package.
struct UpdatePolicyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "policy",
        abstract: "Set the update mode and provider of an Android app."
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Option(name: .long, help: "automatic, notify, or manual.")
    var mode: String

    @Option(name: .long, help: "A provider spec such as local:/path/to/repo.")
    var provider: String?

    @Flag(name: .long, help: "Remove the configured provider.")
    var noProvider = false

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        let choice: UpdateChoice
        switch mode {
        case "automatic": choice = .automatic
        case "notify": choice = .notifyOnly
        case "manual": choice = .manual
        default:
            throw CLIFailure.invalidArgument(argument: "--mode", reason: "invalidValue")
        }
        guard !(provider != nil && noProvider) else {
            throw CLIFailure.invalidArgument(argument: "--provider/--no-provider", reason: "incompatible")
        }

        let providerChange: ProviderChange
        if noProvider {
            providerChange = .remove
        } else if let provider {
            providerChange = .set(try InstallUpdateOptions.providerSpec(provider))
        } else {
            providerChange = .keep
        }

        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let status = try await client.setUpdatePolicy(
                packageID: packageID,
                policy: UpdatePolicy(choice: choice, provider: providerChange))
            let providerText = status.provider?.label ?? "none"
            Output.write(
                "\(status.packageID.rawValue): mode \(status.choice?.rawValue ?? status.authority), provider \(providerText)"
            )
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }

}

/// `apkrun update history [<package>]` (cli.md §4.3): the update history.
struct UpdateHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show the update history of Android apps."
    )

    @Argument(help: "The Android package name. Omit it for every package.")
    var package: String?

    @Option(name: .long, help: "The maximum entries (default 50, max 1000).")
    var limit: Int?

    @Flag(name: .long, help: "Print the history as JSON.")
    var json = false

    mutating func run() async throws {
        var packageID: RuntimePackageID?
        if let package {
            guard let parsed = RuntimePackageID(rawValue: package) else {
                throw CLIFailure.invalidPackageName(package: package)
            }
            packageID = parsed
        }
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let entries = try await client.updateHistory(packageID: packageID, limit: limit)
            if json {
                try PackageQueryOutput.writeJSON(entries)
            } else {
                for entry in entries {
                    Output.write(UpdateOutput.historyLine(entry))
                }
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// Terminal formatting of update results (cli.md §4.3).
enum UpdateOutput {
    /// One line per checked package.
    static func line(_ result: UpdateCheckResult) -> String {
        let package = result.packageID.rawValue
        switch result.outcome {
        case .upToDate:
            return "\(package): up to date"
        case .available(let candidate):
            return "\(package): update available: \(candidateText(candidate))"
        case .installed(let from, let to):
            return "\(package): installed: \(from) → \(to)"
        case .waiting(let reason):
            return "\(package): waiting: \(reason.rawValue)"
        case .failed(let error):
            return "\(package): failed: \(error.code)"
        }
    }

    /// One history line: `<time> <package>: <trigger> → <outcome>`.
    static func historyLine(_ entry: UpdateHistoryEntry) -> String {
        let formatter = ISO8601DateFormatter()
        let package = entry.packageID.rawValue
        var text = "\(formatter.string(from: entry.time)) \(package): \(entry.trigger) → \(entry.outcome)"
        if let failure = entry.failure {
            text += " (\(failure.code))"
        }
        return text
    }

    /// `v1.2 (42)` or `42` of a candidate.
    static func candidateText(_ candidate: WireUpdateCandidate) -> String {
        let code = candidate.versionCode.map(String.init) ?? "unknown"
        if let name = candidate.versionName {
            return "\(name) (\(code))"
        }
        return code
    }
}

/// `apkrun update skip <package> <versionCode>` (§8.4, cli.md §4.3):
/// refuses the version on the next checks until unskipped.
struct UpdateSkipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "Skip an update version so it is not offered again."
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Argument(help: "The versionCode to skip.")
    var versionCode: Int64

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            try await client.updateSkipped(
                packageID: packageID, versionCode: versionCode, skipped: true)
            Output.write("\(package): version \(versionCode) skipped")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun update unskip <package> <versionCode>` (§8.4, cli.md §4.3):
/// removes the skip so the version is offered again.
struct UpdateUnskipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unskip",
        abstract: "Offer a skipped update version again."
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Argument(help: "The versionCode to unskip.")
    var versionCode: Int64

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            try await client.updateSkipped(
                packageID: packageID, versionCode: versionCode, skipped: false)
            Output.write("\(package): version \(versionCode) unskipped")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

/// `apkrun rollback <package> [--allow-data-loss]` (§8.5, cli.md §4.3):
/// rolls back to `previous/`. App data is never rolled back;
/// `--allow-data-loss` is the confirmed Restore choice that erases it.
struct RollbackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Roll an app back to its previous version."
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Flag(name: .long, help: "Allow the data-erasing restore fallback.")
    var allowDataLoss = false

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let reply = try await client.rollbackPackage(
                packageID: packageID, allowDataLoss: allowDataLoss)
            if let to = reply.rolledBackTo {
                Output.write(
                    "\(package): rolled back to version \(to). App data was not changed.")
            } else {
                Output.writeLogLine(
                    "\(package): no previous version to roll back to, or no rollback mechanism is available.",
                    toStandardError: true
                )
                throw ExitCode.failure
            }
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}

#if !APKRUN_EMBEDDED_RUNTIME
/// `apkrun repair <package> [--yes]` (package-store.md §11.1, cli.md §4.3):
/// reinstalls a `broken` package from its retained `current/` artifacts.
/// The daemon refuses when the package is not broken.
struct RepairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Reinstall a broken app from APKRun's retained APKs."
    )

    @Argument(help: "The Android package name.")
    var package: String

    @Flag(name: .long, help: "Repair without asking for confirmation.")
    var yes = false

    mutating func run() async throws {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw CLIFailure.invalidPackageName(package: package)
        }
        try CLIConfirmation.confirm(
            "Reinstall \(package) from APKRun's retained APKs?", yes: yes)
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let handle = try await client.repairPackage(packageID: packageID)
            let snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                using: client,
                operationID: handle.operationID,
                progressToStderr: OperationCommandOutput.shouldShowProgress
            )
            if case .failed(let wireError)? = snapshot.result {
                throw wireError
            }
            Output.write("\(package): reinstalled from the retained APKs.")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }
}
#endif
