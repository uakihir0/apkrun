#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Darwin
    import RuntimeHost

    struct DevAdbCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "adb",
            abstract: "Run adb against the development Android at 127.0.0.1:6520 by default."
        )

        @Option(name: .long, help: "Loopback TCP port of the development Android (default: 6520).")
        var adbHostPort = DevAdb.defaultHostPort

        @Argument(
            parsing: .captureForPassthrough,
            help: "Arguments for adb, for example: shell getprop sys.boot_completed"
        )
        var arguments: [String] = []

        mutating func run() async throws {
            let status = try await DevAdb().run(arguments: arguments, hostPort: adbHostPort)
            if status != 0 {
                Darwin.exit(status)
            }
        }
    }
#endif
