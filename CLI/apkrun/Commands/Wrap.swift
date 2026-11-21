#if !APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Darwin
    import DiagnosticsCore
    import Foundation
    import RuntimeAPI
    import RuntimeClient

    /// `apkrun wrap <file.apk|package>` creates the Mac app of an Android
    /// app, installing the file first when the §12.2 table says so
    /// (wrapper.md §12.2, cli.md §4.4).
    struct WrapCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wrap",
            abstract: "Install an APK and create its Mac app, or wrap an installed app."
        )

        @Argument(help: "An APK file, or the Android package ID of an installed app.")
        var package: String

        @Option(name: .long, help: "Directory the Mac app is placed in (default: ~/Applications).")
        var output: String?

        @Flag(name: .long, help: "Install the APK file first, as `apkrun install --yes` would.")
        var install = false

        @Option(name: .long, help: "A provider spec such as local:/path or direct:<https-url>.")
        var provider: String?

        @Option(name: .long, help: "Update mode: automatic, notify, or manual.")
        var updates: String?

        @Option(name: .long, help: "Alias for --updates.")
        var update: String?

        @Option(name: .long, help: "Provider type used with --update-url.")
        var updateProvider: String?

        @Option(name: .long, help: "Provider URL used with --update-provider.")
        var updateURL: String?

        @Option(name: .long, help: "The Mac app's name (default: the app's name).")
        var name: String?

        @Option(name: .long, help: "A square PNG of at least 512 px used as the Mac app's icon.")
        var icon: String?

        @Option(name: .long, help: "The default window size, as <w>x<h> points.")
        var windowSize: String?

        @Flag(name: .long, help: "Make the window resizable by default.")
        var resizable = false

        @Flag(name: .long, help: "Make the window fixed-size by default.")
        var noResizable = false

        @Flag(name: .long, help: "Replace this package's existing Mac app.")
        var replace = false

        @Flag(name: .long, help: "Open the Mac app after creating it.")
        var open = false

        @Flag(name: .long, help: "Answer every confirmation with yes.")
        var yes = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            // wrapper.md §12.2: a file goes through importPackage and the
            // preview's relation decides the row of the import/install
            // table; a package ID is wrapped as is.
            let inputURL = URL(fileURLWithPath: package).standardizedFileURL
            let isFile =
                package.hasSuffix(".apk")
                || (FileManager.default.fileExists(atPath: inputURL.path)
                    && !package.isEmpty && RuntimePackageID(rawValue: package) == nil)

            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }

            let packageID: RuntimePackageID
            if isFile {
                let preview = try await WrapCommandSupport.importFile(at: inputURL, client: client)
                switch WrapCommandSupport.filePlan(relation: preview.relation, install: install) {
                case .confirmInstall:
                    DaemonInstallSupport.writePreview(preview)
                    if !yes {
                        guard isatty(STDIN_FILENO) == 1 else {
                            throw RuntimeWireError(
                                domain: "wrapper",
                                code: "wrapper.packageNotInstalled",
                                message: "\(preview.packageID.rawValue) isn't installed in APKRun.",
                                remediation: "Install it too with `apkrun wrap <file> --install`, "
                                    + "or answer yes with --yes.",
                                parameters: ["app": preview.packageID.rawValue]
                            )
                        }
                        try CLIConfirmation.confirm(
                            "Install and create the Mac app?", yes: false)
                    }
                    packageID = try await WrapCommandSupport.installPreview(
                        preview,
                        options: try updateOptions(),
                        client: client
                    )
                case .installAndWrap:
                    DaemonInstallSupport.writePreview(preview)
                    packageID = try await WrapCommandSupport.installPreview(
                        preview,
                        options: try updateOptions(),
                        client: client
                    )
                case .wrapInstalled(let note):
                    try rejectUpdateFlags()
                    Output.writeLogLine(note.text, toStandardError: true)
                    packageID = preview.packageID
                }
            } else {
                guard !install else {
                    throw CLIFailure.invalidArgument(
                        argument: "install",
                        reason: "--install takes an APK file")
                }
                guard let id = RuntimePackageID(rawValue: package) else {
                    throw CLIFailure.invalidArgument(argument: "package", reason: "invalid")
                }
                try rejectUpdateFlags()
                packageID = id
            }

            // The CLI resolves --output with the user's own file access;
            // apkrund never does (cli.md §4.4, wrapper.md §12.2).
            let destination = try WrapCommandSupport.destination(for: output)

            // --icon is a PNG the user's process reads; the daemon never
            // opens the path (cli.md §4.4).
            var iconHandle: FileHandle?
            var iconChoice: WrapperIconChoice?
            if let icon {
                let url = URL(fileURLWithPath: icon).standardizedFileURL
                do {
                    iconHandle = try FileHandle(forReadingFrom: url)
                    iconChoice = .custom(fileIndex: 0)
                } catch {
                    throw CLIFailure.fileNotAccessible(
                        file: url.path, .notFound)
                }
            }
            defer { try? iconHandle?.close() }

            let info = try await WrapCommandSupport.createAndPlace(
                packageID: packageID,
                destination: destination,
                fileName: nil,
                displayName: name,
                icon: iconChoice,
                iconHandle: iconHandle,
                replace: replace ? .sameWrapper : .never,
                windowDefaults: try windowDefaults(),
                client: client
            )
            if open {
                WrapCommandSupport.open(bundleURL: info.summary.bundleURL)
            }
            if json {
                try OperationCommandOutput.writeJSON(info)
            } else {
                Output.write(WrapCommandSupport.resultText(info))
            }
        }

        /// The update flags become install options when this command
        /// installs the package (wrapper.md §12.2).
        private func updateOptions() throws -> RuntimeInstallOptions {
            try InstallUpdateOptions.options(
                provider: provider, updates: updates, update: update,
                updateProvider: updateProvider, updateURL: updateURL)
        }

        /// Update flags on an already-installed package are refused with
        /// the `apkrun update policy` hint (wrapper.md §12.2).
        private func rejectUpdateFlags() throws {
            guard provider == nil, updates == nil, update == nil,
                updateProvider == nil, updateURL == nil
            else {
                throw CLIFailure.invalidArgument(
                    argument: "updates",
                    reason: "the app is already installed; use `apkrun update policy`")
            }
        }

        private func windowDefaults() throws -> WrapperWindowDefaultsWire? {
            var defaults = WrapperWindowDefaultsWire()
            if let windowSize {
                let parts = windowSize.lowercased().split(separator: "x")
                guard parts.count == 2,
                    let width = Int(parts[0]), width > 0,
                    let height = Int(parts[1]), height > 0
                else {
                    throw CLIFailure.invalidArgument(
                        argument: "window-size", reason: "expected <w>x<h>")
                }
                defaults.defaultWidth = width
                defaults.defaultHeight = height
            }
            guard !(resizable && noResizable) else {
                throw CLIFailure.invalidArgument(
                    argument: "resizable", reason: "use only one of --resizable and --no-resizable")
            }
            if resizable { defaults.resizable = true }
            if noResizable { defaults.resizable = false }
            return defaults.defaultWidth == nil && defaults.resizable == nil ? nil : defaults
        }
    }

    /// `apkrun wrapper` subcommands that inspect Mac apps
    /// (wrapper.md §12.2): `verify` checks a bundle, `info` shows the
    /// registry row of a package's wrapper.
    struct WrapperCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wrapper",
            abstract: "Inspect the Mac apps APKRun created.",
            subcommands: [WrapperVerifyCommand.self, WrapperInfoCommand.self]
        )
    }

    struct WrapperVerifyCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Check a Mac app bundle against the registry and the signature checks."
        )

        @Argument(help: "The .app bundle to check.")
        var path: String

        @Flag(name: .long, help: "Add the strict all-architecture signature check and the hash list.")
        var deep = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            let verification = try await client.verifyWrapper(bundleURL: url, deep: deep)
            if json {
                try OperationCommandOutput.writeJSON(verification)
            } else {
                Output.write(WrapCommandSupport.verificationText(verification))
            }
            // A bundle that is missing, unreadable, modified, or not the
            // package's wrapper is not valid (wrapper.md §9.1).
            guard verification.state == .valid, verification.problems.isEmpty
            else {
                throw ExitCode(2)
            }
        }
    }

    struct WrapperInfoCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info",
            abstract: "Show the registry row of a package's Mac app."
        )

        @Argument(help: "The Android package ID.")
        var package: String

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            guard let packageID = RuntimePackageID(rawValue: package) else {
                throw CLIFailure.invalidPackageName(package: package)
            }
            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            let info = try await client.wrapperInfo(packageID: packageID)
            if json {
                try OperationCommandOutput.writeJSON(info)
            } else {
                Output.write(WrapCommandSupport.infoText(info))
            }
        }
    }

    enum WrapCommandSupport {
        /// What `wrap <file>` does for an import preview relation
        /// (wrapper.md §12.2 table).
        enum FilePlan: Equatable {
            /// Preview, then ask "Install and create the Mac app?".
            case confirmInstall
            /// `--install`: install (as `apkrun install --yes`), then wrap.
            case installAndWrap
            /// Wrap the installed version; the file is not installed.
            case wrapInstalled(WrapNote)
        }

        /// The stderr note of a `wrapInstalled` row.
        enum WrapNote: Equatable {
            case sameVersion
            case newerFile
            case olderFile
            case otherSigner

            var text: String {
                switch self {
                case .sameVersion:
                    "The file's version is already installed; wrapping the installed app."
                case .newerFile:
                    "The file is newer than the installed version; use --install to update first. "
                        + "Wrapping the installed version."
                case .olderFile:
                    "The file is older than the installed version; ignoring it. "
                        + "Wrapping the installed version."
                case .otherSigner:
                    "The file is signed by a different developer; ignoring it. "
                        + "Wrapping the installed version."
                }
            }
        }

        /// The §12.2 import/install table, keyed by the preview's relation.
        static func filePlan(relation: RuntimeImportRelation, install: Bool) -> FilePlan {
            switch relation {
            case .newPackage, .uninstalledWithData, .unknown:
                install ? .installAndWrap : .confirmInstall
            case .sameAsInstalled, .reinstallSameVersion:
                .wrapInstalled(.sameVersion)
            case .update:
                install ? .installAndWrap : .wrapInstalled(.newerFile)
            case .downgrade:
                install ? .installAndWrap : .wrapInstalled(.olderFile)
            case .otherSigner:
                install ? .installAndWrap : .wrapInstalled(.otherSigner)
            }
        }

        /// Resolves `--output` to the wire destination with the user's own
        /// file access (cli.md §4.4).
        static func destination(for output: String?) throws -> WireWrapperDestination? {
            guard let output else { return nil }
            let url = URL(fileURLWithPath: output).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                throw CLIFailure.invalidArgument(argument: "output", reason: "not a directory")
            }
            return .directory(url)
        }

        /// Imports the file and returns the preview; the §12.2 rows read
        /// its relation.
        static func importFile(
            at url: URL,
            client: RuntimeControlClient
        ) async throws -> RuntimeImportPreview {
            let urls = try DaemonInstallSupport.inputFiles([url.path])
            let handles = try urls.map { try DaemonInstallSupport.openRegularFile(at: $0) }
            defer {
                for handle in handles {
                    try? handle.close()
                }
            }
            let sources = urls.enumerated().map { index, url in
                RuntimeImportSourceFile(fileIndex: index, name: url.lastPathComponent)
            }
            do {
                return try await client.importPackage(
                    RuntimeImportPackageRequest(files: sources, origin: .cli),
                    files: handles)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
        }

        /// Installs an already-inspected import (the `apkrun install
        /// --yes` half of `wrap <file> --install`).
        static func installPreview(
            _ preview: RuntimeImportPreview,
            options: RuntimeInstallOptions,
            client: RuntimeControlClient
        ) async throws -> RuntimePackageID {
            let operationID = RuntimeAPI.OperationID()
            let handle: OperationHandle
            do {
                handle = try await client.beginInstallImported(
                    RuntimeInstallImportedRequest(ticket: preview.ticket, options: options),
                    operationID: operationID)
            } catch {
                throw await DaemonInstallSupport.installFailure(
                    error, packageID: preview.packageID, operationID: operationID)
            }
            let snapshot: OperationSnapshot
            do {
                snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                    using: client,
                    operationID: handle.operationID,
                    progressToStderr: OperationCommandOutput.shouldShowProgress)
            } catch {
                throw await DaemonInstallSupport.installWaitFailure(
                    error, packageID: preview.packageID, operationID: operationID)
            }
            let result = try OperationCommandOutput.installedPackage(
                from: snapshot, expectedPackageID: preview.packageID)
            Output.write(
                "Installed \(DaemonInstallSupport.safeTerminalText(result.displayName)) "
                    + "(\(result.packageID.rawValue)), version "
                    + "\(result.versionCode.map(String.init) ?? "unknown").")
            return result.packageID
        }

        /// Runs the `wrapperCreate` operation and, on
        /// `wrapper.destinationNotAccessible`, places the staged bundle
        /// itself (wrapper.md §6.3). Shared by `wrap` and `install --wrap`.
        static func createAndPlace(
            packageID: RuntimePackageID,
            destination: WireWrapperDestination?,
            fileName: String?,
            displayName: String?,
            icon: WrapperIconChoice?,
            iconHandle: FileHandle?,
            replace: WireReplacePolicy,
            windowDefaults: WrapperWindowDefaultsWire?,
            client: RuntimeControlClient
        ) async throws -> WrapperInfo {
            let operationID = RuntimeAPI.OperationID()
            let request = WrapperRequest(
                packageID: packageID,
                destination: destination,
                fileName: fileName,
                displayName: displayName,
                icon: icon,
                replace: replace,
                windowDefaults: windowDefaults
            )
            let handle: OperationHandle
            do {
                handle = try await client.createWrapper(
                    request,
                    icon: iconHandle,
                    operationID: operationID
                )
            } catch {
                throw await beginFailure(error, packageID: packageID, operationID: operationID)
            }

            let snapshot: OperationSnapshot
            do {
                snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                    using: client,
                    operationID: handle.operationID,
                    progressToStderr: OperationCommandOutput.shouldShowProgress
                )
            } catch {
                throw await waitFailure(error, packageID: packageID, operationID: operationID)
            }
            let info: WrapperInfo
            do {
                info = try wrapperInfo(from: snapshot, expectedPackageID: packageID)
            } catch let failure as RuntimeWireError {
                info = try await placeStaged(
                    after: failure, destination: destination, client: client)
            }
            return info
        }

        /// Moves a staged bundle into place after
        /// `wrapper.destinationNotAccessible` (wrapper.md §6.3) and finishes
        /// with `placeStagedWrapper`. Re-throws any other error.
        static func placeStaged(
            after failure: RuntimeWireError,
            destination: WireWrapperDestination?,
            client: RuntimeControlClient
        ) async throws -> WrapperInfo {
            guard failure.code == "wrapper.destinationNotAccessible",
                let token = failure.parameters["stagingToken"]
            else {
                throw failure
            }
            let directory: URL
            switch destination {
            case .directory(let url):
                directory = url
            case nil, .applications, .userApplications:
                directory = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true)
            }
            let paths = APKRunPaths()
            let stagingDir = paths.wrapperStagingDirectory
                .appendingPathComponent(token, isDirectory: true)
            let stagedBundles =
                (try? FileManager.default.contentsOfDirectory(
                    at: stagingDir, includingPropertiesForKeys: nil
                ))?.filter { $0.pathExtension == "app" } ?? []
            guard let stagedBundle = stagedBundles.first else {
                throw failure
            }
            let finalURL = directory.appendingPathComponent(
                stagedBundle.lastPathComponent, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: stagedBundle, to: finalURL)
            } catch {
                throw failure
            }
            let bookmark = try? finalURL.bookmarkData()
            do {
                return try await client.placeStagedWrapper(
                    stagingToken: token,
                    finalURL: finalURL,
                    bookmark: bookmark?.base64EncodedString()
                )
            } catch let clientError as RuntimeControlClientError {
                guard case .remoteFailure(let code, let message, _) = clientError else {
                    throw clientError
                }
                throw RuntimeWireError(domain: "wrapper", code: code, message: message)
            }
        }

        /// Opens the created Mac app with LaunchServices (`--open`).
        static func open(bundleURL: URL) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [bundleURL.path]
            try? process.run()
        }

        /// The `wrapper` output of a finished `wrapperCreate` operation.
        static func wrapperInfo(
            from snapshot: OperationSnapshot,
            expectedPackageID: RuntimePackageID
        ) throws -> WrapperInfo {
            guard snapshot.kind == .wrapperCreate else {
                throw RuntimeWireError.runtime(
                    "operationResultUnknown",
                    message: "APKRun couldn't read the result of the wrap operation."
                )
            }
            try OperationCommandOutput.requireSuccess(snapshot)
            guard case .succeeded(.wrapper(let info))? = snapshot.result,
                info.summary.packageID == expectedPackageID
            else {
                throw RuntimeWireError.runtime(
                    "operationResultUnknown",
                    message: "APKRun couldn't read the result of the wrap operation."
                )
            }
            return info
        }

        /// The one-line human result: the bundle path (cli.md §4.4).
        static func resultText(_ info: WrapperInfo) -> String {
            "Created \(DaemonInstallSupport.safeTerminalText(info.summary.bundleURL.path))"
        }

        /// The human `wrapper verify` report: one line per field plus the
        /// problems a failing bundle carries.
        static func verificationText(_ verification: WrapperVerification) -> String {
            var lines: [String] = []
            if let bundleID = verification.bundleID {
                lines.append("Bundle ID: \(DaemonInstallSupport.safeTerminalText(bundleID))")
            }
            if let packageID = verification.packageID {
                lines.append("Package: \(packageID)")
            }
            if let kind = verification.kind {
                lines.append("Kind: \(kind.rawValue)")
            }
            if let cdhash = verification.cdhash {
                lines.append("CDHash: \(cdhash)")
            }
            if let state = verification.state, state != .valid {
                lines.append("State: \(Self.stateText(state))")
            }
            for problem in verification.problems {
                lines.append("Problem: \(problem.rawValue)")
            }
            if verification.problems.isEmpty,
                verification.state == nil || verification.state == .valid
            {
                lines.append("Valid")
            }
            return lines.joined(separator: "\n")
        }

        /// The one-word state name of a `wrapper verify` report.
        static func stateText(_ state: WrapperState) -> String {
            switch state {
            case .valid: "valid"
            case .moved(let url): "moved(\(url.path))"
            case .missing: "missing"
            case .inaccessible: "inaccessible"
            case .signatureInvalid: "signatureInvalid"
            case .unknownPackage: "unknownPackage"
            }
        }

        /// The human `wrapper info` report.
        static func infoText(_ info: WrapperInfo) -> String {
            [
                "Mac app: \(DaemonInstallSupport.safeTerminalText(info.summary.bundleURL.path))",
                "Bundle ID: \(DaemonInstallSupport.safeTerminalText(info.summary.bundleID))",
                "Package: \(info.summary.packageID.rawValue)",
                "Name: \(DaemonInstallSupport.safeTerminalText(info.summary.displayName))",
                "Kind: \(info.summary.kind.rawValue)",
                "Launcher: \(DaemonInstallSupport.safeTerminalText(info.summary.launcherVersion))",
            ].joined(separator: "\n")
        }

        static func beginFailure(
            _ error: any Error,
            packageID: RuntimePackageID,
            operationID: RuntimeAPI.OperationID
        ) async -> any Error {
            if let wireError = error as? RuntimeWireError {
                return wireError
            }
            if let failure = error as? RuntimeControlClientError,
                case .remoteFailure = failure
            {
                return error
            }
            return await RuntimeStatusOutput.commandFailure(error)
        }

        static func waitFailure(
            _ error: any Error,
            packageID: RuntimePackageID,
            operationID: RuntimeAPI.OperationID
        ) async -> any Error {
            if let wireError = error as? RuntimeWireError {
                return wireError
            }
            if let failure = error as? RuntimeControlClientError,
                case .remoteFailure = failure
            {
                return error
            }
            return await RuntimeStatusOutput.commandFailure(error)
        }
    }
#endif
