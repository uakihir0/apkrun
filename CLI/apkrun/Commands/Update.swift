import ArgumentParser
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun update` (cli.md §4.3): checks managed packages for updates and
/// prints one line per package. Exit code is 2 when any package failed.
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for, list, and manage Android app updates.",
        subcommands: [UpdatePolicyCommand.self, UpdateHistoryCommand.self]
    )

    @Flag(name: .long, help: "Report only; do not download or notify.")
    var checkOnly = false

    @Flag(name: .long, help: "Print the results as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
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
            providerChange = .set(try Self.providerSpec(provider))
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
                "\(status.packageID.rawValue): mode \(status.choice?.rawValue ?? status.authority), provider \(providerText)")
        } catch let failure as RuntimeWireError {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
    }

    /// Parses `local:<path>` into a provider spec carrying a security-scoped
    /// bookmark of the folder (runtime-api.md §9.2). Other schemes land with
    /// their providers (#51–#53).
    private static func providerSpec(_ spec: String) throws -> ProviderSpec {
        if spec.hasPrefix("local:") {
            let path = String(spec.dropFirst("local:".count))
            let url = URL(fileURLWithPath: path)
            guard url.isFileURL else {
                throw CLIFailure.invalidArgument(argument: "--provider", reason: "invalidValue")
            }
            let bookmark: Data
            do {
                bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
            } catch {
                throw CLIFailure.fileNotAccessible(file: path, .permissionDenied)
            }
            return ProviderSpec(spec: spec, bookmark: bookmark)
        }
        return ProviderSpec(spec: spec)
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
