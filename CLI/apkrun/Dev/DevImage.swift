#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Foundation
    import RuntimeHost

    struct DevImageCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "image",
            abstract: "Install development runtime images.",
            subcommands: [DevImageInstallCommand.self]
        )
    }

    struct DevImageInstallCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Install a signed development bundle as the current Android image."
        )

        @Argument(help: "Bundle directory written by `python3 -m apkrun_image bundle`.")
        var bundle: String

        mutating func run() async throws {
            let bundleURL = URL(fileURLWithPath: bundle).standardizedFileURL
            try await DevImage().install(bundleURL: bundleURL) { event in
                switch event {
                case .message(let text):
                    Output.writeLogLine(text, toStandardError: true)
                case .warning(let text):
                    Output.writeLogLine("warning: \(text)", toStandardError: true)
                case .state, .console:
                    break
                }
            }
        }
    }
#endif
