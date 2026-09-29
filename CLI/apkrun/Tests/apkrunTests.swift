import DiagnosticsCore
import Foundation
import Testing
@testable import apkrun

private let goldenDirectory = Bundle.module.resourceURL!.appendingPathComponent("Golden")

@Test func versionHumanOutputMatchesGolden() {
    let version = releaseBuildInfo

    #expect(Output.versionHuman(version) == golden("version-human.txt"))
}

@Test func versionJSONOutputMatchesGolden() {
    let version = releaseBuildInfo

    #expect(Output.versionJSON(version) == golden("version-json.txt"))
}

@Test func versionFlagUsesTheInjectedVersion() {
    let version = releaseBuildInfo

    #expect(Output.versionFlag(version) == golden("version-flag.txt"))
}

@Test func versionCommandParsesJSONFlag() throws {
    let command = try VersionCommand.parse(["--json"])

    #expect(command.json)
}

@Test func rootParserPreservesVersionSubcommandJSONFlag() async throws {
    let parsed = try await APKRunCommand.asyncParseAsRoot(["version", "--json"])

    #expect((parsed as? VersionCommand)?.json == true)
}

@Test func builtInOutputRequestsAreLimitedToSupportedCompletionShells() {
    #expect(APKRunCommand.isBuiltInOutputRequest(["--help"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["-help"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--version"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["help", "version"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script", "zsh"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script=bash"]))
    #expect(!APKRunCommand.isBuiltInOutputRequest([
        "--generate-completion-script",
        "unsupported-shell",
    ]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script=unsupported-shell"]))
    #expect(!APKRunCommand.isBuiltInOutputRequest([
        "--help",
        "--generate-completion-script",
        "unsupported-shell",
    ]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["invalid-command", "help"]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["--", "--help"]))
    #expect(!APKRunCommand.isBuiltInOutputRequest([
        "--generate-completion-script",
        "help",
    ]))
    #expect(APKRunCommand.usesJSONErrorOutput(["--json", "--bogus"]))
    #expect(!APKRunCommand.usesJSONErrorOutput(["--", "--json"]))
}

@Test func versionCommandRendersInjectedVersion() {
    let version = releaseBuildInfo
    var command = VersionCommand(versionInformation: version)
    command.json = false
    #expect(command.renderedOutput == golden("version-human.txt"))

    command.json = true
    #expect(command.renderedOutput == golden("version-json.txt"))
}

@Test func rootHelpMatchesGolden() {
    #expect(APKRunCommand.helpMessage() == golden("help.txt"))
}

@Test func catalogUsageErrorUsesThreeLinesAndExit64() {
    let error = CLIFailure.invalidArguments

    #expect(
        ErrorOutput.render(error, json: false) ==
            """
            error: The command arguments aren't valid.
            hint: Run the command with --help to see the allowed values.
            code: cli.invalidArguments
            """
    )
    #expect(ExitCodes.code(for: error) == 64)
}

@Test func catalogJSONErrorGoesToTheJSONPresenter() throws {
    let error = CLIFailure.invalidPackageName(package: "not a package")
    let output = try #require(
        JSONSerialization.jsonObject(with: Data(ErrorOutput.render(error, json: true).utf8))
            as? [String: Any]
    )
    let details = try #require(output["error"] as? [String: Any])

    #expect(details["code"] as? String == "cli.invalidPackageName")
    #expect(details["message"] as? String == "not a package isn't a valid Android package name.")
    #expect(ExitCodes.code(for: error) == 64)
}

@Test func cliExitTableMatchesGeneratedCatalog() {
    for entry in ErrorCatalog.entries.values where entry.code.hasPrefix("cli.") {
        guard case let .code(expected) = entry.cliExit else {
            Issue.record("CLI entry \(entry.code) must have a fixed exit code.")
            continue
        }
        #expect(ExitCodes.code(for: entry.code) == expected)
    }
}

private func golden(_ name: String) -> String {
    let contents = try! String(contentsOf: goldenDirectory.appendingPathComponent(name), encoding: .utf8)
    return contents.trimmingCharacters(in: .newlines)
}

private let releaseBuildInfo = BuildInfo(
    infoDictionary: [
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "APKRunBuildIdentity": "release",
        "APKRunGitCommit": "abcdef0",
        "APKRunConfiguration": "Release",
        "APKRunEmbeddedRuntime": false,
    ]
)
