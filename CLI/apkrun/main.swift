import ArgumentParser
import Foundation

@main
struct APKRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apkrun",
        abstract: "Run Android apps as Mac apps.",
        version: Output.versionFlag(VersionInformation.current),
        subcommands: [VersionCommand.self]
    )

    mutating func run() async throws {
        Output.write(Self.helpMessage())
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show APKRun version information."
    )

    @Flag(name: .long, help: "Print version information as JSON.")
    var json = false

    private let versionInformation: VersionInformation

    init() {
        versionInformation = .current
    }

    init(versionInformation: VersionInformation) {
        self.versionInformation = versionInformation
    }

    var renderedOutput: String {
        json
            ? Output.versionJSON(versionInformation)
            : Output.versionHuman(versionInformation)
    }

    mutating func run() throws {
        Output.write(renderedOutput)
    }
}
