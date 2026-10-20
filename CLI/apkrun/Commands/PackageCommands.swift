#if APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Darwin
    import Foundation
    import RuntimeAPI
    import RuntimeHost

    struct InstallCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install",
            abstract: "Inspect and install one APK or a set of APK splits."
        )

        @Argument(help: "APK files that form one app, including any required splits.")
        var files: [String]

        @Flag(name: .long, help: "Install without asking for confirmation.")
        var yes = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            guard !files.isEmpty else {
                throw CLIFailure.invalidArgument(argument: "file", reason: "required")
            }
            let urls = try PackageCommandSupport.inputFiles(files)
            let handles = try urls.map { try PackageCommandSupport.openRegularFile(at: $0) }
            defer {
                for handle in handles {
                    try? handle.close()
                }
            }

            let sources = urls.enumerated().map { index, url in
                RuntimeImportSourceFile(fileIndex: index, name: url.lastPathComponent)
            }
            let service = EmbeddedPackageService()
            let preview = try await service.importPackage(
                RuntimeImportPackageRequest(files: sources, origin: .cli),
                files: handles
            )

            let installRequest = RuntimeInstallImportedRequest(
                ticket: preview.ticket,
                options: RuntimeInstallOptions()
            )
            PackageCommandSupport.writePreview(preview)
            try PackageCommandSupport.confirm(
                PackageCommandSupport.installConfirmationPrompt(for: preview),
                yes: yes
            )

            let result = try await PackageCommandSupport.withReadyRuntime(service) {
                try await service.installImported(installRequest)
            }
            PackageCommandSupport.writeInstallResult(result, json: json)
        }
    }

    struct UninstallCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Remove an installed Android app."
        )

        @Argument(help: "The Android package name.")
        var package: String

        @Flag(name: .long, help: "Keep the app's Android data for a later reinstall.")
        var keepData = false

        @Flag(
            name: .long,
            help: ArgumentHelp(
                "Forget APKRun's record and stored APKs without contacting Android or determining the app-data outcome."
            )
        )
        var forget = false

        @Flag(name: .long, help: "Uninstall without asking for confirmation.")
        var yes = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            let packageID = try PackageCommandSupport.packageID(package)
            guard !forget || !keepData else {
                throw CLIFailure.invalidArgument(argument: "--keep-data", reason: "incompatibleWithForget")
            }
            let service = EmbeddedPackageService()
            let options = RuntimeUninstallOptions(keepData: keepData, forget: forget)
            let request = RuntimeUninstallPackageRequest(packageID: packageID, options: options)
            try PackageCommandSupport.confirm(
                forget
                    ? "Forget APKRun's record and stored APKs for \(packageID.rawValue)? This does not determine or change Android app data."
                    : "Uninstall \(packageID.rawValue)\(keepData ? " and keep its data" : " and delete its data")?",
                yes: yes
            )

            if forget {
                try await service.uninstallPackage(request)
                if json {
                    PackageCommandSupport.writeJSON(PackageCommandAcknowledgement(packageID: packageID))
                } else {
                    Output.write("Forgot \(packageID.rawValue).")
                }
                return
            }

            _ = try await PackageCommandSupport.withReadyRuntime(service) {
                try await service.uninstallPackage(request)
                return true
            }
            if json {
                PackageCommandSupport.writeJSON(PackageCommandAcknowledgement(packageID: packageID))
            } else {
                Output.write("Uninstalled \(packageID.rawValue).")
            }
        }
    }

    enum PackageCommandSupport {
        static func packageID(_ rawValue: String) throws -> RuntimePackageID {
            guard let packageID = RuntimePackageID(rawValue: rawValue) else {
                throw CLIFailure.invalidPackageName(package: rawValue)
            }
            return packageID
        }

        static func inputFiles(_ paths: [String]) throws -> [URL] {
            guard !paths.isEmpty else {
                throw CLIFailure.invalidArgument(argument: "file", reason: "required")
            }
            guard paths.count <= 256 else {
                throw CLIFailure.invalidArgument(argument: "file", reason: "tooMany")
            }
            return try paths.map { path in
                let url = URL(fileURLWithPath: path).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    throw CLIFailure.fileNotAccessible(file: url.path, .notFound)
                }
                guard !isDirectory.boolValue else {
                    throw CLIFailure.fileNotAccessible(file: url.path, .isDirectory)
                }
                guard
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else {
                    throw CLIFailure.invalidArgument(argument: "file", reason: "notRegularFile")
                }
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    throw CLIFailure.fileNotAccessible(file: url.path, .permissionDenied)
                }
                return url
            }
        }

        static func openRegularFile(at url: URL) throws -> FileHandle {
            // O_NONBLOCK prevents opening a FIFO from waiting for a writer before fstat can reject it.
            let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else {
                throw CLIFailure.fileNotAccessible(file: url.path, .permissionDenied)
            }
            var details = stat()
            guard Darwin.fstat(descriptor, &details) == 0 else {
                _ = Darwin.close(descriptor)
                throw CLIFailure.fileNotAccessible(file: url.path, .permissionDenied)
            }
            guard details.st_mode & S_IFMT == S_IFREG else {
                _ = Darwin.close(descriptor)
                throw CLIFailure.invalidArgument(argument: "file", reason: "notRegularFile")
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        static func confirm(_ prompt: String, yes: Bool) throws {
            try CLIConfirmation.confirm(prompt, yes: yes)
        }

        static func writePreview(_ preview: RuntimeImportPreview) {
            Output.writeLogLine(
                "App: \(safeTerminalText(preview.displayName))\n"
                    + "Package: \(preview.packageID.rawValue)\n"
                    + "Version: \(preview.versionName.map(safeTerminalText) ?? "unknown") "
                    + "(\(preview.versionCode))\n"
                    + "Files: \(preview.files.count)\n"
                    + "Relation: \(relationName(preview.relation))",
                toStandardError: true
            )
            for warning in preview.warnings {
                Output.writeLogLine("Warning: \(warningName(warning))", toStandardError: true)
            }
        }

        static func safeTerminalText(_ text: String) -> String {
            let replacementCharacter = "\u{FFFD}".unicodeScalars.first
            let sanitized = text.unicodeScalars.map { scalar in
                switch scalar.value {
                case 0x0000...0x001F, 0x007F...0x009F,  // C0/C1 terminal controls
                    0x061C, 0x200E, 0x200F,  // directional marks
                    0x2028, 0x2029,  // Unicode line and paragraph separators
                    0x202A...0x202E, 0x2066...0x2069:  // bidi overrides and isolates
                    replacementCharacter ?? scalar
                default:
                    scalar
                }
            }
            return String(String.UnicodeScalarView(sanitized))
        }

        static func installConfirmationPrompt(for preview: RuntimeImportPreview) -> String {
            let displayName = safeTerminalText(preview.displayName)
            let packageID = preview.packageID.rawValue
            if case .downgrade(let fromVersion) = preview.relation {
                return "The preview shows \(displayName) (\(packageID)) at version "
                    + "\(preview.versionCode), below version \(fromVersion). Recheck Android's "
                    + "current version before continuing? If this is still a downgrade, installation will be refused."
            }
            if case .sameAsInstalled = preview.relation {
                return "Reinstall \(displayName) (\(packageID)) using the selected APK files?"
            }
            return "Install \(displayName) (\(packageID))?"
        }

        static func writeInstallResult(
            _ result: RuntimePackageSummary,
            json: Bool
        ) {
            if json {
                writeJSON(result)
            } else {
                Output.write(
                    "Installed \(safeTerminalText(result.displayName)) "
                        + "(\(result.packageID.rawValue)), version \(result.versionCode)."
                )
            }
        }

        static func writeJSON<Value: Encodable>(_ value: Value) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            do {
                let envelope = PackageCommandJSONEnvelope(result: value)
                let data = try encoder.encode(envelope)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            } catch {
                ErrorOutput.write(
                    RuntimeWireError.runtime(
                        "internal",
                        message: "APKRun couldn't encode the package result.",
                        remediation: "Try the command again. If it keeps failing, report the problem."
                    ), json: true)
            }
        }

        static func withReadyRuntime<Value: Sendable>(
            _ service: EmbeddedPackageService,
            operation: @escaping @Sendable () async throws -> Value
        ) async throws -> Value {
            let environment = ProcessInfo.processInfo.environment
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let stopRequests = AsyncStream.makeStream(of: Void.self)
            let result = PackageCommandResultBox<Value>()
            let options = DevBootOptions(
                stopWhenReady: true,
                guestAgentDirectory: DevGuestAgentLocation.directory(
                    guestDir: nil,
                    environment: environment,
                    executable: executable
                )
            )
            try await DevBoot().run(
                options: options,
                environment: environment,
                stopRequests: stopRequests.stream,
                onRuntimeReady: { context in
                    try await service.attachRuntime(context: context, environment: environment)
                    await result.store(try await operation())
                    return service
                },
                onEvent: { event in
                    switch event {
                    case .message(let text):
                        Output.writeLogLine(text, toStandardError: true)
                    case .warning(let text):
                        Output.writeLogLine("warning: \(text)", toStandardError: true)
                    case .catalogWarning(let error):
                        ErrorOutput.write(error, json: false)
                    case .state, .console, .windowStatus, .windowTitle,
                        .appWindowStatus, .appWindowTitle, .appWindowExited:
                        break
                    }
                }
            )
            guard let value = await result.load() else {
                throw RuntimeWireError.runtime(
                    "serviceUnavailable",
                    message: "Android stopped before the package operation completed.",
                    remediation: "Start Android and try again."
                )
            }
            return value
        }

        private static func relationName(_ relation: RuntimeImportRelation) -> String {
            switch relation {
            case .newPackage: "new package"
            case .sameAsInstalled: "same stored APK set (will reinstall)"
            case .reinstallSameVersion: "reinstall same version"
            case .update: "update"
            case .downgrade: "downgrade"
            case .otherSigner: "different signer"
            case .uninstalledWithData: "reinstall and keep data"
            case .unknown: "unknown"
            }
        }

        private static func warningName(_ warning: RuntimeImportWarning) -> String {
            switch warning {
            case .missingHardwareFeature(let feature): "the app requests \(feature)"
            case .certificateOnlyVerification: "the signing check is not complete"
            case .signingNotChecked: "Android will verify the APK signature during installation"
            case .debuggable: "the app is marked debuggable"
            case .lowTargetSDK(let target): "the app targets older Android API \(target)"
            }
        }
    }

    private struct PackageCommandJSONEnvelope<Value: Encodable>: Encodable {
        let schemaVersion = 1
        let result: Value
    }

    private struct PackageCommandAcknowledgement: Encodable {
        let packageID: RuntimePackageID
        let removed = true
    }

    private actor PackageCommandResultBox<Value: Sendable> {
        private var value: Value?

        func store(_ value: Value) {
            self.value = value
        }

        func load() -> Value? {
            value
        }
    }
#endif
