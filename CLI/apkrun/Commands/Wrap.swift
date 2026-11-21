#if !APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import DiagnosticsCore
    import Foundation
    import RuntimeAPI
    import RuntimeClient

    /// `apkrun wrap <package>` creates the Mac app of an installed package
    /// (wrapper.md §12.2, cli.md §4.4). `apkrun wrap <file.apk>` is #76.
    struct WrapCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wrap",
            abstract: "Create the Mac app of an installed Android app."
        )

        @Argument(help: "The Android package ID of an installed app, or an APK file with --install.")
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

        @Flag(name: .long, help: "Replace this package's existing Mac app.")
        var replace = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            // wrapper.md §12.2: `wrap <file.apk> --install` installs the file
            // (`apkrun install --yes` semantics) and wraps the package that
            // landed. A package ID is wrapped as is; a file requires
            // --install.
            let inputURL = URL(fileURLWithPath: package).standardizedFileURL
            let isFile =
                package.hasSuffix(".apk")
                || (FileManager.default.fileExists(atPath: inputURL.path)
                    && !package.isEmpty && RuntimePackageID(rawValue: package) == nil)
            guard isFile == install else {
                throw CLIFailure.invalidArgument(
                    argument: isFile ? "install" : "package",
                    reason: isFile
                        ? "an APK file needs --install"
                        : "--install takes an APK file")
            }

            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }

            var packageID: RuntimePackageID
            if install {
                let installOptions = try InstallUpdateOptions.options(
                    provider: provider, updates: updates, update: update,
                    updateProvider: updateProvider, updateURL: updateURL)
                packageID = try await WrapCommandSupport.installFile(
                    at: inputURL, options: installOptions, client: client)
            } else {
                guard let id = RuntimePackageID(rawValue: package) else {
                    throw CLIFailure.invalidArgument(argument: "package", reason: "invalid")
                }
                packageID = id
            }

            // The CLI resolves --output with the user's own file access;
            // apkrund never does (cli.md §4.4, wrapper.md §12.2).
            let destination: WireWrapperDestination?
            if let output {
                let url = URL(fileURLWithPath: output).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    throw CLIFailure.invalidArgument(argument: "output", reason: "not a directory")
                }
                destination = .directory(url)
            } else {
                destination = nil
            }

            let operationID = RuntimeAPI.OperationID()
            let request = WrapperRequest(
                packageID: packageID,
                destination: destination,
                replace: replace ? .sameWrapper : .never
            )
            let handle: OperationHandle
            do {
                handle = try await client.createWrapper(
                    request,
                    icon: nil,
                    operationID: operationID
                )
            } catch {
                throw await WrapCommandSupport.beginFailure(
                    error,
                    packageID: packageID,
                    operationID: operationID
                )
            }

            let snapshot: OperationSnapshot
            do {
                snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                    using: client,
                    operationID: handle.operationID,
                    progressToStderr: OperationCommandOutput.shouldShowProgress
                )
            } catch {
                throw await WrapCommandSupport.waitFailure(
                    error,
                    packageID: packageID,
                    operationID: handle.operationID
                )
            }
            let info: WrapperInfo
            do {
                info = try WrapCommandSupport.wrapperInfo(
                    from: snapshot,
                    expectedPackageID: packageID
                )
            } catch let failure as RuntimeWireError {
                // wrapper.md §6.3: when the daemon's probe hit EPERM the
                // bundle waits in staging and the client — this process,
                // which the user can grant folder access — moves it and
                // calls placeStagedWrapper to finish.
                info = try await WrapCommandSupport.placeStaged(
                    after: failure, destination: destination, replace: replace,
                    client: client)
            }
            if json {
                try OperationCommandOutput.writeJSON(info)
            } else {
                Output.write(WrapCommandSupport.resultText(info))
            }
        }
    }

    enum WrapCommandSupport {
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
            // The target folder the daemon could not reach; the staged
            // bundle keeps the name the daemon chose (the sole .app in the
            // token's staging directory).
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

        /// Imports and installs the APK (the `apkrun install --yes` half of
        /// `wrap <file> --install`) and returns the installed package ID.
        static func installFile(
            at url: URL,
            options: RuntimeInstallOptions,
            client: RuntimeControlClient
        ) async throws -> RuntimePackageID {
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
            let preview: RuntimeImportPreview
            do {
                preview = try await client.importPackage(
                    RuntimeImportPackageRequest(files: sources, origin: .cli),
                    files: handles)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }
            DaemonInstallSupport.writePreview(preview)

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
