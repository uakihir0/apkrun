import ArgumentParser
import DiagnosticsCore
import Foundation

enum LogsLevel: String, CaseIterable, ExpressibleByArgument {
    case info
    case debug

    static var allValueStrings: [String] {
        allCases.map(\.rawValue)
    }

    var logLevel: LogLevel {
        switch self {
        case .info: .info
        case .debug: .debug
        }
    }
}

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Read APKRun host logs."
    )

    @Flag(name: .long, help: "Continue streaming new log entries.")
    var follow = false

    @Option(
        name: .long, help: "Read entries from the last duration (for example 5m or 1h, up to 30d).")
    var since: String?

    @Option(name: .long, help: "Filter to an io.apkrun subsystem prefix.")
    var subsystem: String?

    @Option(name: .long, help: "Include info or debug entries.")
    var level: LogsLevel?

    @Flag(name: .long, help: "Print one JSON object per line.")
    var json = false

    mutating func run() async throws {
        try await Self.execute(
            follow: follow,
            since: since,
            subsystem: subsystem,
            level: level,
            json: json,
            reader: LogReader(paths: APKRunPaths()),
            output: Self.writeOutput
        )
    }

    static func execute(
        follow: Bool,
        since: String?,
        subsystem: String?,
        level: LogsLevel?,
        json: Bool,
        reader: LogReader,
        output: @escaping @Sendable (String, Bool) -> Void
    ) async throws {
        let requestedDuration = since ?? "1h"
        guard LogReader.isValidDuration(requestedDuration) else {
            throw CLIFailure.invalidArgument(argument: "--since", reason: "duration")
        }
        if let subsystem, !Self.isValidSubsystem(subsystem) {
            throw CLIFailure.invalidArgument(argument: "--subsystem", reason: "subsystem")
        }

        let options = LogReadOptions(
            follow: follow,
            since: requestedDuration,
            subsystem: subsystem,
            level: level?.logLevel
        )
        let report = try await reader.read(options) { [output, json] event in
            switch event {
            case .entry(let record):
                output(json ? record.jsonLine : record.humanLine, false)
            case .usingMirrors:
                output("note: including available APKRun file mirrors.", true)
            }
        }
        if !report.hasReadableSource {
            throw CLIFailure.logsUnavailable
        }
    }

    private static func isValidSubsystem(_ value: String) -> Bool {
        value.range(
            of: #"^io\.apkrun(?:\.[A-Za-z0-9_-]+)*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func writeOutput(_ text: String, _ toStandardError: Bool) {
        Output.writeLogLine(text, toStandardError: toStandardError)
    }
}
