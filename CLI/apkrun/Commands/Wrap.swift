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

        @Argument(help: "The Android package ID of an installed app.")
        var package: String

        @Option(name: .long, help: "Directory the Mac app is placed in (default: ~/Applications).")
        var output: String?

        @Flag(name: .long, help: "Replace this package's existing Mac app.")
        var replace = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            guard let packageID = RuntimePackageID(rawValue: package) else {
                throw CLIFailure.invalidArgument(argument: "package", reason: "invalid")
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

            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
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
                if FileManager.default.fileExists(atPath: finalURL.path) {
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
                    // replaceItemAt swaps atomically: the existing wrapper
                    // survives a failed move instead of being deleted first.
                    _ = try FileManager.default.replaceItemAt(
                        finalURL, withItemAt: stagedBundle)
                } else {
                    try FileManager.default.moveItem(at: stagedBundle, to: finalURL)
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
