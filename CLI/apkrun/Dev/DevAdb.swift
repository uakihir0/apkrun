#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Darwin
    import RuntimeHost

    struct DevAdbCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "adb",
            abstract: "Run adb against the development Android at 127.0.0.1:6520."
        )

        @Argument(
            parsing: .captureForPassthrough,
            help: "Arguments for adb, for example: shell getprop sys.boot_completed"
        )
        var arguments: [String] = []

        mutating func run() async throws {
            let status = try await DevAdb().run(arguments: arguments)
            if status != 0 {
                Darwin.exit(status)
            }
        }
    }
#endif
