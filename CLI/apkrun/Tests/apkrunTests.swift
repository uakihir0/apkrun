import DiagnosticsCore
import DiagnosticsCoreTestSupport
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

@Test func devLinuxFloodArgumentsUseDefaultAndExplicitLineCounts() throws {
    #expect(
        try DevLinuxFloodArguments.make(tests: ["flood"], lineCount: nil)
            == ["apkrun.test.flood=10000000"]
    )
    #expect(
        try DevLinuxFloodArguments.make(tests: ["flood"], lineCount: 1234)
            == ["apkrun.test.flood=1234"]
    )
    #expect(try DevLinuxFloodArguments.make(tests: ["ports"], lineCount: nil).isEmpty)
}

@Test func devLinuxFloodArgumentsRejectMisuseAndOutOfRangeCounts() {
    do {
        _ = try DevLinuxFloodArguments.make(tests: ["ports"], lineCount: 100)
        Issue.record("flood line count without the flood test unexpectedly succeeded")
    } catch CLIFailure.invalidArgument(let argument, let reason) {
        #expect(argument == "--flood-lines")
        #expect(reason == "requiresFloodTest")
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    do {
        _ = try DevLinuxFloodArguments.make(tests: ["flood"], lineCount: 10_000_001)
        Issue.record("out-of-range flood line count unexpectedly succeeded")
    } catch CLIFailure.invalidArgument(let argument, let reason) {
        #expect(argument == "--flood-lines")
        #expect(reason == "range")
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}

@Test func builtInOutputRequestsAreLimitedToSupportedCompletionShells() {
    #expect(APKRunCommand.isBuiltInOutputRequest(["--help"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["-help"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--version"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["help", "version"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script", "zsh"]))
    #expect(APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script=bash"]))
    #expect(
        !APKRunCommand.isBuiltInOutputRequest([
            "--generate-completion-script",
            "unsupported-shell",
        ]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["--generate-completion-script=unsupported-shell"]))
    #expect(
        !APKRunCommand.isBuiltInOutputRequest([
            "--help",
            "--generate-completion-script",
            "unsupported-shell",
        ]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["invalid-command", "help"]))
    #expect(!APKRunCommand.isBuiltInOutputRequest(["--", "--help"]))
    #expect(
        !APKRunCommand.isBuiltInOutputRequest([
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

@Test func versionCommandWritesOneNoticeToTheCLICommandSubsystem() throws {
    let sink = RecordingLogSink()
    let logger = APKLogger(category: .command, sink: sink)
    VersionCommand.recordInvocation(using: logger)

    #expect(sink.entries.count == 1)
    #expect(sink.entries.first?.level == .notice)
    #expect(sink.entries.first?.subsystem == .cli)
    #expect(sink.entries.first?.category == "command")
}

@Test func logsCommandWritesNormalizedJSONEntriesFromTheInjectedRunner() async throws {
    let timestamp = ISO8601DateFormatter().string(from: .now)
    let line =
        #"{"timestamp":"\#(timestamp)","messageType":"Info","eventMessage":"ready","subsystem":"io.apkrun.cli","category":"command"}"#
    let runner = FakeLogCommandRunner(results: [
        LogCommandResult(exitCode: 0, standardOutput: Data(line.utf8))
    ])
    let paths = APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory)
    let output = CLIOutputRecorder()
    try await LogsCommand.execute(
        follow: false,
        since: "5m",
        subsystem: "io.apkrun.cli",
        level: .info,
        json: true,
        reader: LogReader(paths: paths, runner: runner),
        output: output.append
    )

    #expect(output.lines.count == 1)
    #expect(output.lines.first?.toStandardError == false)
    #expect(output.lines.first?.text.contains(#""message":"ready""#) == true)
    let arguments = await runner.recordedArguments()
    #expect(arguments.first?.first == "show")
}

@Test func logsCommandRejectsInvalidFiltersWithCatalogExitCode64() async throws {
    let runner = FakeLogCommandRunner(results: [])
    let paths = APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory)
    let output = CLIOutputRecorder()
    do {
        try await LogsCommand.execute(
            follow: false,
            since: "5m --predicate true",
            subsystem: nil,
            level: nil,
            json: false,
            reader: LogReader(paths: paths, runner: runner),
            output: output.append
        )
        Issue.record("invalid duration unexpectedly succeeded")
    } catch let failure as CLIFailure {
        #expect(failure.code == "invalidArgument")
        #expect(ExitCodes.code(for: failure) == 64)
    }
    #expect(output.lines.isEmpty)
}

@Test func logsCommandRejectsSubsystemOutsideAPKRunNamespace() async throws {
    let runner = FakeLogCommandRunner(results: [])
    let paths = APKRunPaths(homeDirectory: FileManager.default.temporaryDirectory)
    let output = CLIOutputRecorder()
    do {
        try await LogsCommand.execute(
            follow: false,
            since: "5m",
            subsystem: #"io.apkrun.cli" OR true"#,
            level: nil,
            json: false,
            reader: LogReader(paths: paths, runner: runner),
            output: output.append
        )
        Issue.record("invalid subsystem unexpectedly succeeded")
    } catch let failure as CLIFailure {
        #expect(failure.code == "invalidArgument")
        #expect(ExitCodes.code(for: failure) == 64)
    }

    #expect(await runner.recordedArguments().isEmpty)
    #expect(output.lines.isEmpty)
}

@Test func logsCommandReportsUnavailableWhenNeitherSourceCanBeRead() async throws {
    let runner = FakeLogCommandRunner(results: [LogCommandResult(exitCode: 1)])
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogsUnavailable-\(UUID().uuidString)", isDirectory: true)
    let paths = APKRunPaths(homeDirectory: directory)
    let output = CLIOutputRecorder()
    do {
        try await LogsCommand.execute(
            follow: false,
            since: "5m",
            subsystem: nil,
            level: nil,
            json: false,
            reader: LogReader(paths: paths, runner: runner),
            output: output.append
        )
        Issue.record("unavailable logs unexpectedly succeeded")
    } catch let failure as CLIFailure {
        #expect(failure.code == "logsUnavailable")
        #expect(ExitCodes.code(for: failure) == 1)
    }
}

@Test func logsCommandNotesReadableMirrorFallbackOnStandardError() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("APKRun-LogsMirror-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(homeDirectory: directory)
    try FileManager.default.createDirectory(at: paths.logsRoot, withIntermediateDirectories: true)
    let timestamp = ISO8601DateFormatter().string(from: .now)
    try "\(timestamp) notice io.apkrun.cli/command fallback"
        .write(to: paths.daemonLogFile, atomically: true, encoding: .utf8)
    let output = CLIOutputRecorder()

    try await LogsCommand.execute(
        follow: false,
        since: "5m",
        subsystem: nil,
        level: nil,
        json: false,
        reader: LogReader(
            paths: paths,
            runner: FakeLogCommandRunner(results: [LogCommandResult(exitCode: 1)])
        ),
        output: output.append
    )

    #expect(
        output.lines.contains {
            $0.toStandardError && $0.text == "note: including available APKRun file mirrors."
        })
    #expect(output.lines.contains { !$0.toStandardError && $0.text.contains(" fallback") })
}

@Test func rootHelpMatchesGolden() {
    #expect(APKRunCommand.helpMessage() == golden("help.txt"))
}

private final class CLIOutputRecorder: @unchecked Sendable {
    struct Line: Equatable {
        let text: String
        let toStandardError: Bool
    }

    private let lock = NSLock()
    private var storedLines: [Line] = []

    var lines: [Line] {
        lock.lock()
        defer { lock.unlock() }
        return storedLines
    }

    func append(_ text: String, _ toStandardError: Bool) {
        lock.lock()
        storedLines.append(Line(text: text, toStandardError: toStandardError))
        lock.unlock()
    }
}

@Test func catalogUsageErrorUsesThreeLinesAndExit64() {
    let error = CLIFailure.invalidArguments

    #expect(
        ErrorOutput.render(error, json: false) == """
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
        guard case .code(let expected) = entry.cliExit else {
            Issue.record("CLI entry \(entry.code) must have a fixed exit code.")
            continue
        }
        #expect(ExitCodes.code(for: entry.code) == expected)
    }
}

private func golden(_ name: String) -> String {
    let contents = try! String(
        contentsOf: goldenDirectory.appendingPathComponent(name), encoding: .utf8)
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
