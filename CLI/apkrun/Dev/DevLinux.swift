#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import DiagnosticsCore
    import Foundation
    import RuntimeHost

    struct DevCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "dev",
            abstract: "Run development-only APKRun commands.",
            subcommands: [
                DevLinuxCommand.self, DevConsoleCommand.self, DevBootCommand.self,
                DevImageCommand.self, DevAdbCommand.self, DevLaunchCommand.self,
            ]
        )
    }

    struct DevLinuxCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "linux",
            abstract: "Boot the minimal Linux test guest."
        )

        @Option(name: .long, help: "Path to the uncompressed ARM64 Linux kernel.")
        var kernel: String?

        @Option(name: .long, help: "Path to the gzip-compressed initramfs.")
        var initrd: String?

        @Option(name: .long, help: "Comma-separated test names to request from the guest.")
        var tests: String?

        @Option(name: .long, help: "Number of lines for the flood test (1–10000000).")
        var floodLines: Int?

        @Option(name: .long, help: "Seconds to wait for the guest's done marker (1–86400).")
        var timeout = 60

        mutating func run() async throws {
            guard (1...86_400).contains(timeout) else {
                throw CLIFailure.invalidArgument(argument: "--timeout", reason: "range")
            }

            let requestedTests: [String]
            if let tests {
                requestedTests = tests.split(separator: ",", omittingEmptySubsequences: false)
                    .map(String.init)
                guard
                    !requestedTests.isEmpty,
                    requestedTests.allSatisfy(Self.isValidTestName),
                    Set(requestedTests).count == requestedTests.count
                else {
                    throw CLIFailure.invalidArgument(argument: "--tests", reason: "testName")
                }
            } else {
                requestedTests = []
            }
            let extraCommandLine = try DevLinuxFloodArguments.make(
                tests: requestedTests,
                lineCount: floodLines
            )

            #if DEBUG
                let override = ProcessInfo.processInfo.environment["APKRUN_TEST_LINUX_DIR"]
            #else
                let override: String? = nil
            #endif
            let artifactDirectory: URL
            if let override, !override.isEmpty {
                guard override.hasPrefix("/") else {
                    throw RuntimeFailure.devLinuxArtifactDirectoryMustBeAbsolute
                }
                artifactDirectory =
                    URL(
                        fileURLWithPath: override,
                        isDirectory: true
                    ).standardizedFileURL
            } else {
                artifactDirectory = URL(
                    fileURLWithPath: "/tmp/apkrun-test-linux",
                    isDirectory: true
                )
            }

            let options = DevLinuxOptions(
                kernelURL: kernel.map { URL(fileURLWithPath: $0) }
                    ?? artifactDirectory.appendingPathComponent("Image"),
                initrdURL: initrd.map { URL(fileURLWithPath: $0) }
                    ?? artifactDirectory.appendingPathComponent("initramfs.cpio.gz"),
                tests: requestedTests,
                timeoutSeconds: timeout,
                extraCommandLine: extraCommandLine
            )
            try await DevLinux().run(options: options) { event in
                switch event {
                case .console(let data):
                    FileHandle.standardOutput.write(data)
                case .warning(let message):
                    Output.writeLogLine("warning: \(message)", toStandardError: true)
                case .record, .state:
                    break
                }
            }
        }

        private static func isValidTestName(_ name: String) -> Bool {
            guard !name.isEmpty, name.utf8.count <= 64 else { return false }
            return name.utf8.allSatisfy { byte in
                (byte >= 48 && byte <= 57)
                    || (byte >= 65 && byte <= 90)
                    || (byte >= 97 && byte <= 122)
                    || byte == 45
                    || byte == 95
            }
        }
    }
#endif
