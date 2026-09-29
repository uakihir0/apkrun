import ArgumentParser
import DiagnosticsCore
import Foundation
import Darwin

@main
struct APKRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apkrun",
        abstract: "Run Android apps as Mac apps.",
        version: Output.versionFlag(BuildInfo.current),
        subcommands: [VersionCommand.self]
    )

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let shouldRenderJSON = usesJSONErrorOutput(arguments)
        var command: ParsableCommand
        do {
            command = try await Self.asyncParseAsRoot(arguments)
        } catch let cleanExit as CleanExit {
            Self.exit(withError: cleanExit)
        } catch {
            if Self.isBuiltInOutputRequest(arguments) {
                Self.exit(withError: error)
            }
            let usageError = CLIFailure.invalidArguments
            ErrorOutput.write(usageError, json: shouldRenderJSON)
            Darwin.exit(Int32(ExitCodes.code(for: usageError)))
        }

        do {
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let cleanExit as CleanExit {
            Self.exit(withError: cleanExit)
        } catch {
            if Self.isBuiltInOutputRequest(arguments) {
                Self.exit(withError: error)
            }
            ErrorOutput.write(error, json: shouldRenderJSON)
            Darwin.exit(Int32(ExitCodes.code(for: error)))
        }
    }

    static func isBuiltInOutputRequest(_ arguments: [String]) -> Bool {
        let activeArguments = Array(arguments.prefix(while: { $0 != "--" }))
        for (index, argument) in activeArguments.enumerated() {
            let option = "--generate-completion-script"
            if argument.hasPrefix("\(option)=") {
                return supportedCompletionShells.contains(
                    String(argument.dropFirst(option.count + 1))
                )
            }
            guard argument == option else {
                continue
            }
            if activeArguments.indices.contains(index + 1) {
                let shell = activeArguments[index + 1]
                return supportedCompletionShells.contains(shell)
            }
            let shell = ProcessInfo.processInfo.environment["SHELL"]
                .map { URL(fileURLWithPath: $0).lastPathComponent }
            return shell.map(supportedCompletionShells.contains) ?? false
        }
        let builtInOptions = ["-h", "-help", "--help", "--version", "--experimental-dump-help"]
        return activeArguments.contains(where: builtInOptions.contains)
            || activeArguments.first == "help"
    }

    static func usesJSONErrorOutput(_ arguments: [String]) -> Bool {
        arguments.prefix(while: { $0 != "--" }).contains("--json")
    }

    private static let supportedCompletionShells: Set<String> = [
        "bash",
        "fish",
        "zsh",
    ]

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

    private let versionInformation: BuildInfo

    init() {
        versionInformation = .current
    }

    init(versionInformation: BuildInfo) {
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
