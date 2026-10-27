import ArgumentParser
import Foundation
import RuntimeAPI
import Testing

@testable import apkrun

@Test func wrapperApprovalCommandParsesBundlePathAndConfirmationFlag() async throws {
    let command = try await WrapperApprovalTestRoot.asyncParseAsRoot([
        "wrapper", "approve", "/Applications/Discord.app", "--yes", "--json",
    ])

    #expect((command as? WrapperApproveCommand)?.path == "/Applications/Discord.app")
    #expect((command as? WrapperApproveCommand)?.yes == true)
    #expect((command as? WrapperApproveCommand)?.json == true)
}

@Test func wrapperApprovalPromptPrintsValidatedFacts() throws {
    let packageID = try #require(RuntimePackageID(rawValue: "com.discord"))
    let signer = try #require(
        RuntimeWrapperSignerSummary(
            kind: .teamSigned,
            teamIdentifier: "TEAM123ABC"
        )
    )
    let approvalUUID = try #require(UUID(uuidString: "41f9ed7b-a123-4ebd-9a61-7a2be9465780"))
    let prompt = try #require(
        RuntimeWrapperApprovalPrompt(
            approvalID: ApprovalID(rawValue: approvalUUID),
            bundlePath: "/Applications/Discord.app",
            bundleID: "io.apkrun.android.com.discord",
            packageID: packageID,
            displayName: "Discord",
            signer: signer,
            packageInstalled: false,
            installedVersion: nil,
            bundledVersion: "1.2.3",
            integrations: RuntimeWrapperIntegrationSummary(
                clipboard: true,
                notifications: false,
                links: true,
                files: false,
                sharedFolders: false,
                microphone: false
            ),
            replacingBundlePath: "/Applications/Old Discord.app"
        )
    )

    #expect(
        WrapperApprovalCommandOutput.prompt(prompt)
            == """
            Location: /Applications/Discord.app
            Bundle ID: io.apkrun.android.com.discord
            Signer: Signed by team: TEAM123ABC
            Android package: not installed
            This Mac app contains version: 1.2.3
            Replaces wrapper: /Applications/Old Discord.app
            Integrations this wrapper would receive: clipboard, links
            """
    )
    #expect(!WrapperApprovalCommandOutput.prompt(prompt).contains("Allow “Discord”"))
}

@Test func wrapperApprovalPromptPrintsInstalledAndroidVersion() throws {
    let prompt = try makeWrapperApprovalPrompt(packageInstalled: true, installedVersion: "8.1.0")

    #expect(
        WrapperApprovalCommandOutput.prompt(prompt).contains("Installed Android app version: 8.1.0")
    )
}

@Test func wrapperApprovalJSONIncludesApprovalResultAndAvailableFacts() throws {
    let prompt = try makeWrapperApprovalPrompt(packageInstalled: true, installedVersion: "8.1.0")
    let data = Data(try WrapperApprovalCommandOutput.approvedJSON(prompt).utf8)
    let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(envelope["result"] as? [String: Any])

    #expect(envelope["schemaVersion"] as? Int == 1)
    #expect(result["approved"] as? Bool == true)
    #expect(result["packageID"] as? String == "com.example.approval")
    #expect(result["installedVersion"] as? String == "8.1.0")
}

@Test func wrapperApprovalRequiresTerminalBeforePreparingPromptUnlessYesIsSet() async throws {
    var approvalPreparationStarted = false
    var confirmationRequired = false

    do {
        _ = try await WrapperApprovalConfirmationFlow.prepareAfterTerminalCheck(
            yes: false,
            isTerminal: false
        ) {
            approvalPreparationStarted = true
            return try makeWrapperApprovalPrompt()
        }
    } catch let failure as CLIFailure {
        confirmationRequired = failure.code == "confirmationRequired"
    }

    #expect(confirmationRequired)
    #expect(!approvalPreparationStarted)
    _ = try await WrapperApprovalConfirmationFlow.prepareAfterTerminalCheck(
        yes: true,
        isTerminal: false
    ) {
        approvalPreparationStarted = true
        return try makeWrapperApprovalPrompt()
    }
    #expect(approvalPreparationStarted)
}

@Test func wrapperApprovalDoesNotSendDenialWhenConfirmationIsRequired() async throws {
    let prompt = try makeWrapperApprovalPrompt()
    let decisions = WrapperApprovalDecisionRecorder()
    var confirmationRequired = false

    do {
        try await WrapperApprovalConfirmationFlow.confirmAndDecide(
            prompt: prompt,
            yes: false,
            confirm: { _, _ in
                throw CLIFailure.confirmationRequired(flag: "--yes")
            },
            decide: { _, allow in
                await decisions.append(allow)
            }
        )
    } catch let failure as CLIFailure {
        confirmationRequired = failure.code == "confirmationRequired"
    }

    #expect(confirmationRequired)
    #expect(await decisions.values.isEmpty)
}

@Test func wrapperApprovalSendsDenialWhenUserDeclines() async throws {
    let prompt = try makeWrapperApprovalPrompt()
    let decisions = WrapperApprovalDecisionRecorder()
    var declined = false

    do {
        try await WrapperApprovalConfirmationFlow.confirmAndDecide(
            prompt: prompt,
            yes: false,
            confirm: { _, _ in
                throw CLIFailure.declined
            },
            decide: { _, allow in
                await decisions.append(allow)
            }
        )
    } catch let failure as CLIFailure {
        declined = failure.code == "declined"
    }

    #expect(declined)
    #expect(await decisions.values == [false])
}

@Test func wrapperApprovalApprovesAfterSuccessfulConfirmation() async throws {
    let prompt = try makeWrapperApprovalPrompt()
    let decisions = WrapperApprovalDecisionRecorder()

    try await WrapperApprovalConfirmationFlow.confirmAndDecide(
        prompt: prompt,
        yes: true,
        confirm: { _, _ in },
        decide: { _, allow in await decisions.append(allow) }
    )

    #expect(await decisions.values == [true])
}

private struct WrapperApprovalTestRoot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apkrun",
        subcommands: [WrapperCommand.self]
    )
}

private func makeWrapperApprovalPrompt(
    packageInstalled: Bool = false,
    installedVersion: String? = nil
) throws -> RuntimeWrapperApprovalPrompt {
    let packageID = try #require(RuntimePackageID(rawValue: "com.example.approval"))
    let signer = try #require(RuntimeWrapperSignerSummary(kind: .adHoc))
    let approvalUUID = try #require(UUID(uuidString: "41f9ed7b-a123-4ebd-9a61-7a2be9465780"))
    return try #require(
        RuntimeWrapperApprovalPrompt(
            approvalID: ApprovalID(rawValue: approvalUUID),
            bundlePath: "/Applications/Example.app",
            bundleID: "io.apkrun.android.com.example.approval",
            packageID: packageID,
            displayName: "Example",
            signer: signer,
            packageInstalled: packageInstalled,
            installedVersion: installedVersion,
            integrations: RuntimeWrapperIntegrationSummary(
                clipboard: false,
                notifications: false,
                links: false,
                files: false,
                sharedFolders: false,
                microphone: false
            )
        )
    )
}

private actor WrapperApprovalDecisionRecorder {
    private var decisions: [Bool] = []

    func append(_ allow: Bool) {
        decisions.append(allow)
    }

    var values: [Bool] {
        decisions
    }
}
