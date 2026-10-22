import ArgumentParser
import Darwin
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

@main
struct APKRunCommand: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        #if APKRUN_EMBEDDED_RUNTIME
            CommandConfiguration(
                commandName: "apkrun",
                abstract: "Run Android apps as Mac apps.",
                version: Output.versionFlag(BuildInfo.current),
                subcommands: [
                    VersionCommand.self,
                    StatusCommand.self,
                    RuntimeCommand.self,
                    ConfigCommand.self,
                    LogsCommand.self,
                    InstallCommand.self,
                    UninstallCommand.self,
                    ListPackagesCommand.self,
                    PackageInfoCommand.self,
                    LaunchCommand.self,
                    StopCommand.self,
                    DevCommand.self,
                ]
            )
        #else
            CommandConfiguration(
                commandName: "apkrun",
                abstract: "Run Android apps as Mac apps.",
                version: Output.versionFlag(BuildInfo.current),
                subcommands: [
                    VersionCommand.self,
                    StatusCommand.self,
                    RuntimeCommand.self,
                    ConfigCommand.self,
                    LogsCommand.self,
                    InstallCommand.self,
                    UninstallCommand.self,
                    ListPackagesCommand.self,
                    PackageInfoCommand.self,
                    LaunchCommand.self,
                    StopCommand.self,
                    OperationsCommand.self,
                ]
            )
        #endif
    }

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        #if APKRUN_EMBEDDED_RUNTIME
            if let request = DisplayWindowSession.request(in: arguments) {
                // AppKit runs on this thread, which is the main thread until the first suspension. Nothing is awaited
                // before the loop starts, so the loop never runs inside an actor job or a main-queue block (IR-1103).
                DisplayWindowSession.runEventLoop(
                    showStatistics: arguments.contains("--stats"),
                    stopsAppOnClose: request == .launch
                ) {
                    await runCommand(arguments)
                }
                return
            }
        #endif
        await runCommand(arguments)
    }

    static func runCommand(_ arguments: [String]) async {
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

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show APKRun version information."
    )

    @Flag(name: .long, help: "Print version information as JSON.")
    var json = false

    private let versionInformation: BuildInfo

    init() {
        self.init(versionInformation: .current)
    }

    init(versionInformation: BuildInfo) {
        self.versionInformation = versionInformation
    }

    var renderedOutput: String {
        renderedOutput(runtimeDetails: nil)
    }

    func renderedOutput(runtimeDetails: VersionRuntimeDetails?) -> String {
        json
            ? Output.versionJSON(versionInformation, runtimeDetails: runtimeDetails)
            : Output.versionHuman(versionInformation, runtimeDetails: runtimeDetails)
    }

    func resolvedOutput() async -> String {
        await Self.resolvedOutput(
            versionInformation: versionInformation,
            json: json
        )
    }

    static func resolvedOutput(
        versionInformation: BuildInfo,
        json: Bool
    ) async -> String {
        await resolvedOutput(
            versionInformation: versionInformation,
            json: json,
            runtimeInfoProvider: loadRuntimeDetails
        )
    }

    static func resolvedOutput(
        versionInformation: BuildInfo,
        json: Bool,
        runtimeInfoProvider: @Sendable () async -> VersionRuntimeDetails?
    ) async -> String {
        let runtimeDetails = await runtimeInfoProvider()
        return json
            ? Output.versionJSON(versionInformation, runtimeDetails: runtimeDetails)
            : Output.versionHuman(versionInformation, runtimeDetails: runtimeDetails)
    }

    mutating func run() async throws {
        Self.recordInvocation(using: APKLogger(category: .command))
        Output.write(await resolvedOutput())
    }

    private static func loadRuntimeDetails() async -> VersionRuntimeDetails? {
        do {
            let client = try RuntimeControlClient(clientKind: .cli)
            let hello = try await client.connect()
            let status = try? await client.runtimeStatus()
            return VersionRuntimeDetails(
                daemonVersion: hello.runtimeVersion,
                daemonBuild: hello.runtimeBuild,
                imageVersion: status?.imageVersion
            )
        } catch {
            return nil
        }
    }

    static func recordInvocation(using logger: APKLogger) {
        logger.notice("version command completed")
    }
}
