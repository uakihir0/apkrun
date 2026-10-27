import ArgumentParser
import Darwin
import Foundation
import RuntimeAPI
import RuntimeClient

struct WrapperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wrapper",
        abstract: "Approve and manage APKRun Mac app wrappers.",
        subcommands: [
            WrapperApproveCommand.self
        ]
    )

    mutating func run() throws {
        Output.write(Self.helpMessage())
    }
}

struct WrapperApproveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "approve",
        abstract: "Review and approve a wrapper app bundle."
    )

    @Argument(help: "The wrapper .app bundle path.")
    var path: String

    @Flag(name: .long, help: "Approve without asking for confirmation.")
    var yes = false

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    mutating func run() async throws {
        let client: RuntimeControlClient
        let prompt: RuntimeWrapperApprovalPrompt
        do {
            (client, prompt) = try await WrapperApprovalConfirmationFlow.prepareAfterTerminalCheck(
                yes: yes,
                isTerminal: isatty(STDIN_FILENO) == 1
            ) {
                let client = try RuntimeControlClient(clientKind: .cli)
                let prompt = try await client.approveWrapper(
                    at: URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                )
                return (client, prompt)
            }
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }

        Output.writeLogLine(
            WrapperApprovalCommandOutput.prompt(prompt),
            toStandardError: true
        )

        do {
            try await WrapperApprovalConfirmationFlow.confirmAndDecide(
                prompt: prompt,
                yes: yes,
                confirm: CLIConfirmation.confirm
            ) { approvalID, allow in
                try await client.decideWrapperApproval(approvalID: approvalID, allow: allow)
            }
        } catch let failure as CLIFailure {
            throw failure
        } catch {
            throw await RuntimeStatusOutput.commandFailure(error)
        }
        if json {
            Output.write(try WrapperApprovalCommandOutput.approvedJSON(prompt))
        } else {
            Output.write(WrapperApprovalCommandOutput.approved(prompt))
        }
    }
}

enum WrapperApprovalConfirmationFlow {
    static func prepareAfterTerminalCheck<Value>(
        yes: Bool,
        isTerminal: Bool,
        prepare: () async throws -> Value
    ) async throws -> Value {
        try requireInteractiveTerminal(yes: yes, isTerminal: isTerminal)
        return try await prepare()
    }

    static func requireInteractiveTerminal(yes: Bool, isTerminal: Bool) throws {
        guard yes || isTerminal else {
            throw CLIFailure.confirmationRequired(flag: "--yes")
        }
    }

    static func confirmAndDecide(
        prompt: RuntimeWrapperApprovalPrompt,
        yes: Bool,
        confirm: (String, Bool) throws -> Void,
        decide: (ApprovalID, Bool) async throws -> Void
    ) async throws {
        do {
            try confirm(WrapperApprovalCommandOutput.confirmationQuestion(for: prompt), yes)
        } catch let failure as CLIFailure {
            switch failure {
            case .declined:
                try await decide(prompt.approvalID, false)
            case .confirmationRequired:
                break
            default:
                throw failure
            }
            throw failure
        }
        try await decide(prompt.approvalID, true)
    }
}

enum WrapperApprovalCommandOutput {
    static func prompt(_ prompt: RuntimeWrapperApprovalPrompt) -> String {
        var lines = [
            "Location: \(safeTerminalText(prompt.bundlePath))",
            "Bundle ID: \(prompt.bundleID)",
            "Signer: \(signerDescription(prompt.signer))",
            "Android package: \(prompt.packageInstalled ? "installed" : "not installed")",
        ]
        if let installedVersion = prompt.installedVersion {
            lines.append("Installed Android app version: \(safeTerminalText(installedVersion))")
        }
        if let bundledVersion = prompt.bundledVersion {
            lines.append(
                "\(prompt.packageInstalled ? "Bundled app version" : "This Mac app contains version"): "
                    + safeTerminalText(bundledVersion)
            )
        }
        if let replacingBundlePath = prompt.replacingBundlePath {
            lines.append("Replaces wrapper: \(safeTerminalText(replacingBundlePath))")
        }
        lines.append("Integrations this wrapper would receive: \(integrationDescription(prompt.integrations))")
        return lines.joined(separator: "\n")
    }

    static func confirmationQuestion(for prompt: RuntimeWrapperApprovalPrompt) -> String {
        "Allow “\(safeTerminalText(prompt.displayName))” to open \(prompt.packageID.rawValue) in APKRun?"
    }

    static func approved(_ prompt: RuntimeWrapperApprovalPrompt) -> String {
        "Approved “\(safeTerminalText(prompt.displayName))” (\(prompt.packageID.rawValue))."
    }

    static func approvedJSON(_ prompt: RuntimeWrapperApprovalPrompt) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            WrapperApprovalJSONEnvelope(
                result: WrapperApprovalJSONResult(prompt: prompt)
            )
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func signerDescription(_ signer: RuntimeWrapperSignerSummary) -> String {
        switch signer.kind {
        case .adHoc:
            return "Ad hoc (not signed by a developer)"
        case .developerID:
            let team = signer.teamIdentifier.map(safeTerminalText) ?? "unknown team"
            let notarized = signer.notarized.map { $0 ? "yes" : "no" } ?? "not assessed"
            return "Developer ID: \(team) (notarized: \(notarized))"
        case .teamSigned:
            let team = signer.teamIdentifier.map(safeTerminalText) ?? "unknown team"
            return "Signed by team: \(team)"
        case .unknown(let kind):
            let safeKind = safeTerminalText(kind)
            if let teamIdentifier = signer.teamIdentifier {
                return "Unknown signer type: \(safeKind) (team \(safeTerminalText(teamIdentifier)))"
            }
            return "Unknown signer type: \(safeKind)"
        }
    }

    private static func integrationDescription(_ integrations: RuntimeWrapperIntegrationSummary) -> String {
        var enabled: [String] = []
        if integrations.clipboard { enabled.append("clipboard") }
        if integrations.notifications { enabled.append("notifications") }
        if integrations.links { enabled.append("links") }
        if integrations.files { enabled.append("file transfer") }
        if integrations.sharedFolders { enabled.append("shared folders") }
        if integrations.microphone { enabled.append("microphone") }
        return enabled.isEmpty ? "none" : enabled.joined(separator: ", ")
    }

    private static func safeTerminalText(_ text: String) -> String {
        let replacement: Unicode.Scalar = "\u{FFFD}"
        let sanitized = text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0000...0x001F, 0x007F...0x009F,
                0x061C, 0x200E, 0x200F,
                0x2028, 0x2029,
                0x202A...0x202E, 0x2066...0x2069:
                replacement
            default:
                scalar
            }
        }
        return String(String.UnicodeScalarView(sanitized))
    }
}

private struct WrapperApprovalJSONEnvelope: Encodable {
    let schemaVersion = 1
    let result: WrapperApprovalJSONResult
}

private struct WrapperApprovalJSONResult: Encodable {
    let approved = true
    let bundlePath: String
    let bundleID: String
    let packageID: RuntimePackageID
    let displayName: String
    let signer: RuntimeWrapperSignerSummary
    let packageInstalled: Bool
    let installedVersion: String?
    let bundledVersion: String?
    let integrations: RuntimeWrapperIntegrationSummary
    let replacingBundlePath: String?

    init(prompt: RuntimeWrapperApprovalPrompt) {
        bundlePath = prompt.bundlePath
        bundleID = prompt.bundleID
        packageID = prompt.packageID
        displayName = prompt.displayName
        signer = prompt.signer
        packageInstalled = prompt.packageInstalled
        installedVersion = prompt.installedVersion
        bundledVersion = prompt.bundledVersion
        integrations = prompt.integrations
        replacingBundlePath = prompt.replacingBundlePath
    }
}
