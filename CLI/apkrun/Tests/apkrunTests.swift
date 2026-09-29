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
