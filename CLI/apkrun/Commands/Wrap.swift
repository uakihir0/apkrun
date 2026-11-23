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
            let fileExists = FileManager.default.fileExists(atPath: inputURL.path)
            let isValidPackageID =
                !package.isEmpty && RuntimePackageID(rawValue: package) != nil
            // A valid package ID names the installed package; a file wins only
            // when it is no valid ID or it is a real `.apk` on disk (a path
            // like ./com.example keeps working through the same rule).
            let isFile =
                (fileExists && !isValidPackageID)
                || (package.lowercased().hasSuffix(".apk") && (fileExists || !isValidPackageID))
            // A missing .apk path is a file error like `apkrun install`
            // reports, not a package-ID lookup.
            if !fileExists, package.lowercased().hasSuffix(".apk") {
                throw CLIFailure.fileNotAccessible(file: inputURL.path, .notFound)
            }

            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }

            // The CLI resolves --output with the user's own file access;
            // apkrund never does (cli.md §4.4, wrapper.md §12.2). Validate it
            // before any install so a bad path fails before the APK lands.
            let destination = try WrapCommandSupport.destination(for: output)

            let packageID: RuntimePackageID
            var installedByThisRun = false
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
                        json: json,
                        client: client
                    )
                    installedByThisRun = true
                case .installAndWrap:
                    DaemonInstallSupport.writePreview(preview)
                    packageID = try await WrapCommandSupport.installPreview(
                        preview,
                        options: try updateOptions(),
                        json: json,
                        client: client
                    )
                    installedByThisRun = true
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

            let info: WrapperInfo
            do {
                info = try await WrapCommandSupport.createAndPlace(
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
            } catch {
                // cli.md §3: installed but the Mac app could not be created
                // is a partial success, exit code 2.
                if installedByThisRun {
                    ErrorOutput.write(error, json: json)
                    throw ExitCode(Int32(ExitCodes.partial))
                }
                throw error
            }
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
            subcommands: [
                WrapperListCommand.self,
                WrapperInfoCommand.self,
                WrapperRefreshCommand.self,
                WrapperRemoveCommand.self,
                WrapperVerifyCommand.self,
            ]
        )
    }

    /// `apkrun wrapper list` (wrapper.md §12.2): the registry's wrappers
    /// with their current status.
    struct WrapperListCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List the Mac apps APKRun created."
        )

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            let entries = try await client.listWrappers()
            if json {
                try OperationCommandOutput.writeJSON(entries.map(\.summary))
            } else {
                Output.write(WrapCommandSupport.listText(entries))
            }
        }
    }

    /// `apkrun wrapper refresh` (wrapper.md §12.2, §9.3): regenerates the
    /// Mac app of one or more packages, or `--all`.
    struct WrapperRefreshCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "refresh",
            abstract: "Regenerate the Mac app of a package, or all Mac apps."
        )

        @Argument(help: "The Android package IDs to refresh.")
        var packages: [String] = []

        @Flag(name: .long, help: "Refresh every registered Mac app.")
        var all = false

        @Option(name: .long, help: "The new display name; an empty string resets it.")
        var name: String?

        @Option(name: .long, help: "A PNG file that replaces the icon.")
        var icon: String?

        @Flag(name: .long, help: "Restore the current Android icon.")
        var androidIcon = false

        @Flag(name: .long, help: "Only refresh the launcher executable.")
        var launcherOnly = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            guard all == packages.isEmpty else {
                throw CLIFailure.invalidArgument(
                    argument: "packages",
                    reason: "name package IDs or pass --all, not both")
            }
            if all {
                guard name == nil, icon == nil, !androidIcon else {
                    throw CLIFailure.invalidArgument(
                        argument: "--all",
                        reason: "--name, --icon and --android-icon refresh one package")
                }
            }
            guard icon == nil || !androidIcon else {
                throw CLIFailure.invalidArgument(
                    argument: "--icon",
                    reason: "--icon and --android-icon exclude each other")
            }
            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            if all {
                let result = try await WrapCommandSupport.runRefreshAll(
                    launcherOnly: launcherOnly, client: client)
                if json {
                    try OperationCommandOutput.writeJSON(result)
                } else {
                    Output.write(WrapCommandSupport.batchText(result))
                }
                if !result.failed.isEmpty {
                    throw ExitCode(2)
                }
                return
            }
            var infos: [WrapperInfo] = []
            for package in packages {
                guard let packageID = RuntimePackageID(rawValue: package) else {
                    throw CLIFailure.invalidPackageName(package: package)
                }
                let info = try await WrapCommandSupport.runRefresh(
                    packageID: packageID,
                    name: name,
                    icon: icon,
                    androidIcon: androidIcon,
                    launcherOnly: launcherOnly,
                    client: client
                )
                infos.append(info)
            }
            if json {
                try OperationCommandOutput.writeJSON(infos)
            } else {
                for info in infos {
                    Output.write(WrapCommandSupport.refreshText(info))
                }
            }
        }
    }

    /// `apkrun wrapper remove` (wrapper.md §12.2, §9.5): drops the registry
    /// entry; `--trash` also moves the bundle to the Trash.
    struct WrapperRemoveCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Remove a package's Mac app."
        )

        @Argument(help: "The Android package ID.")
        var package: String

        @Flag(name: .long, help: "Move the Mac app to the Trash.")
        var trash = false

        @Flag(name: .long, help: "Answer confirmation prompts with yes.")
        var yes = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            guard let packageID = RuntimePackageID(rawValue: package) else {
                throw CLIFailure.invalidPackageName(package: package)
            }
            try CLIConfirmation.confirm(
                trash
                    ? "Move the Mac app of \(package) to the Trash?"
                    : "Remove the Mac app of \(package) from the list?",
                yes: yes)
            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            let removed = try await client.removeWrapper(packageID: packageID, trash: trash)
            guard removed else {
                throw CLIFailure.invalidArgument(
                    argument: "package",
                    reason: "\(package) has no Mac app")
            }
            if json {
                try OperationCommandOutput.writeJSON(
                    RemoveResult(package: packageID.rawValue))
            } else {
                Output.write(
                    trash
                        ? "Moved the Mac app of \(packageID.rawValue) to the Trash."
                        : "Removed the Mac app of \(packageID.rawValue) from the list.")
            }
        }
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

    /// The `wrapper remove --json` payload.
    struct RemoveResult: Codable {
        var package: String
        var removed = true
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
            json: Bool,
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
            if !json {
                Output.write(
                    "Installed \(DaemonInstallSupport.safeTerminalText(result.displayName)) "
                        + "(\(result.packageID.rawValue)), version "
                        + "\(result.versionCode.map(String.init) ?? "unknown").")
            }
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
                // wrapper.md §6.3: when the daemon's probe hit EPERM the
                // bundle waits in staging and the client — this process,
                // which the user can grant folder access — moves it and
                // calls placeStagedWrapper to finish.
                info = try await placeStaged(
                    after: failure, destination: destination,
                    replace: replace == .sameWrapper,
                    client: client)
            }
            return info
        }

        /// Moves a staged bundle into place after
        /// `wrapper.destinationNotAccessible` (wrapper.md §6.3) and finishes
        /// with `placeStagedWrapper`. Re-throws any other error.
        static func placeStaged(
            after failure: RuntimeWireError,
            destination: WireWrapperDestination?,
            replace: Bool,
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
                // The daemon skipped the conflict check on the deferred path;
                // honor it here the way place() does (wrapper.md §6.4):
                // --replace swaps only this package's own wrapper, never an
                // item that belongs to anything else.
                let destinationExists = FileManager.default.fileExists(
                    atPath: finalURL.path)
                if destinationExists {
                    let existingPackage = plistPackageID(of: finalURL)
                    guard replace, existingPackage != nil,
                        existingPackage == plistPackageID(of: stagedBundle)
                    else {
                        throw RuntimeWireError(
                            domain: "wrapper",
                            code: "wrapper.nameConflict",
                            message: "An item named \(finalURL.lastPathComponent) "
                                + "already exists there.",
                            remediation: "Choose another name or location. "
                                + "APKRun never replaces it.",
                            parameters: ["file": finalURL.lastPathComponent])
                    }
                }
                // Move via a temp name in the destination folder, the same
                // path moveIntoPlace takes: it survives a different volume
                // (replaceItemAt requires one) and keeps the existing wrapper
                // in place until the swap.
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let temp = directory.appendingPathComponent(
                    ".\(finalURL.lastPathComponent).apkrun-\(UUID().uuidString)",
                    isDirectory: true)
                try FileManager.default.moveItem(at: stagedBundle, to: temp)
                do {
                    if destinationExists {
                        _ = try FileManager.default.replaceItemAt(
                            finalURL, withItemAt: temp)
                    } else {
                        try FileManager.default.moveItem(at: temp, to: finalURL)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: temp)
                    throw error
                }
            } catch let moveError as RuntimeWireError {
                throw moveError
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

        /// Reads `APKRunPackageID` from a bundle's Info.plist; nil means the
        /// item is not an APKRun wrapper (or is unreadable).
        static func plistPackageID(of bundle: URL) -> String? {
            let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                let plist = try? PropertyListSerialization.propertyList(
                    from: data, format: nil) as? [String: Any]
            else { return nil }
            return plist["APKRunPackageID"] as? String
        }

        /// The `wrapper` output of a finished `wrapperCreate` operation.
        static func wrapperInfo(
            from snapshot: OperationSnapshot,
            expectedPackageID: RuntimePackageID
        ) throws -> WrapperInfo {
            guard snapshot.kind == .wrapperCreate || snapshot.kind == .wrapperRefresh else {
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

        /// The human `wrapper list` report: one row per wrapper.
        static func listText(_ entries: [WrapperListEntryWire]) -> String {
            guard !entries.isEmpty else {
                return "No Mac apps."
            }
            let rows = entries.map { entry in
                let state = entry.state.map(stateText) ?? "unknownPackage"
                return [
                    DaemonInstallSupport.safeTerminalText(entry.summary.displayName),
                    entry.summary.packageID.rawValue,
                    state,
                    DaemonInstallSupport.safeTerminalText(entry.summary.bundleURL.path),
                ].joined(separator: "\t")
            }
            return (["NAME\tPACKAGE\tSTATUS\tPATH"] + rows).joined(separator: "\n")
        }

        /// The one-line human result of `wrapper refresh` for one package.
        static func refreshText(_ info: WrapperInfo) -> String {
            "Updated \(DaemonInstallSupport.safeTerminalText(info.summary.bundleURL.path))"
        }

        /// The human `wrapper refresh --all` report.
        static func batchText(_ result: WrapperBatchResult) -> String {
            var lines = ["Updated \(result.refreshed.count) Mac app(s)."]
            for packageID in result.skippedRunning {
                lines.append("Skipped \(packageID.rawValue) (the app is running).")
            }
            for failure in result.failed {
                lines.append(
                    "Failed \(failure.packageID.rawValue): \(failure.error.message)")
            }
            return lines.joined(separator: "\n")
        }

        /// Runs `refreshWrapper` for one package and waits for the result;
        /// `wrapper.wrapperRunning` asks "Quit ‹App›?" and retries with
        /// `closeRunningApp` (wrapper.md §9.3 step 1).
        static func runRefresh(
            packageID: RuntimePackageID,
            name: String?,
            icon: String?,
            androidIcon: Bool,
            launcherOnly: Bool,
            client: RuntimeControlClient
        ) async throws -> WrapperInfo {
            var iconHandle: FileHandle?
            if let icon {
                let url = URL(fileURLWithPath: icon).standardizedFileURL
                do {
                    iconHandle = try FileHandle(forReadingFrom: url)
                } catch {
                    throw CLIFailure.fileNotAccessible(file: url.path, .notFound)
                }
            }
            defer { try? iconHandle?.close() }
            let operationID = RuntimeAPI.OperationID()
            do {
                return try await refreshAndWait(
                    packageID: packageID,
                    change: WrapperRefreshWire(
                        displayName: name,
                        icon: icon != nil,
                        androidIcon: androidIcon,
                        launcherOnly: launcherOnly
                    ),
                    icon: iconHandle,
                    operationID: operationID,
                    client: client
                )
            } catch {
                guard Self.isWrapperRunning(error) else { throw error }
                let app = errorWrapperApp(error) ?? packageID.rawValue
                try CLIConfirmation.confirm(
                    "Quit \(app) to update its Mac app?", yes: false)
                return try await refreshAndWait(
                    packageID: packageID,
                    change: WrapperRefreshWire(
                        displayName: name,
                        icon: icon != nil,
                        androidIcon: androidIcon,
                        launcherOnly: launcherOnly,
                        closeRunningApp: true
                    ),
                    icon: iconHandle,
                    operationID: RuntimeAPI.OperationID(),
                    client: client
                )
            }
        }

        /// Whether an error is `wrapper.wrapperRunning`, whether it came
        /// from begin, wait, or the operation result.
        static func isWrapperRunning(_ error: any Error) -> Bool {
            if let wire = error as? RuntimeWireError {
                return wire.code == "wrapper.wrapperRunning"
            }
            if let failure = error as? RuntimeControlClientError,
                case .remoteFailure(let code, _, _) = failure
            {
                return code == "wrapper.wrapperRunning"
            }
            return false
        }

        /// The app name a `wrapper.wrapperRunning` error carries.
        static func errorWrapperApp(_ error: any Error) -> String? {
            if let wire = error as? RuntimeWireError {
                return wire.parameters["app"]
            }
            if let failure = error as? RuntimeControlClientError,
                case .remoteFailure(_, _, let parameters) = failure
            {
                return parameters["app"]
            }
            return nil
        }

        private static func refreshAndWait(
            packageID: RuntimePackageID,
            change: WrapperRefreshWire,
            icon: FileHandle?,
            operationID: RuntimeAPI.OperationID,
            client: RuntimeControlClient
        ) async throws -> WrapperInfo {
            let handle: OperationHandle
            do {
                handle = try await client.refreshWrapper(
                    packageID: packageID,
                    change: change,
                    icon: icon,
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
            return try wrapperInfo(from: snapshot, expectedPackageID: packageID)
        }

        /// Runs `refreshAllWrappers` and waits for the batch result.
        static func runRefreshAll(
            launcherOnly: Bool,
            client: RuntimeControlClient
        ) async throws -> WrapperBatchResult {
            let operationID = RuntimeAPI.OperationID()
            let handle: OperationHandle
            do {
                handle = try await client.refreshAllWrappers(
                    scope: .all,
                    launcherOnly: launcherOnly,
                    operationID: operationID
                )
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            let snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                using: client,
                operationID: handle.operationID,
                progressToStderr: OperationCommandOutput.shouldShowProgress
            )
            guard case .succeeded(let output)? = snapshot.result,
                case .wrapperBatch(let result) = output
            else {
                if case .failed(let wireError)? = snapshot.result {
                    throw wireError
                }
                throw RuntimeWireError.runtime(
                    "operationResultUnknown",
                    message: "APKRun couldn't read the result of the refresh operation."
                )
            }
            return result
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