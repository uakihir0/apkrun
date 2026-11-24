#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import DiagnosticsCore
    import Foundation
    import RuntimeHost

    struct DevPowerCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "power",
            abstract: "Inject a host sleep or wake event into a running development runtime."
        )

        @Argument(help: "Power event to inject: sleep or wake.")
        var action: String

        mutating func run() async throws {
            guard let action = DevPowerAction(rawValue: action) else {
                throw CLIFailure.invalidArgument(argument: "action", reason: "power")
            }
            let paths = APKRunPaths(
                allowingHomeOverride: true,
                environment: ProcessInfo.processInfo.environment
            )
            try DevControlSocketClient.injectPower(action, directory: paths.devConsoleDirectory)
        }
    }
#endif
