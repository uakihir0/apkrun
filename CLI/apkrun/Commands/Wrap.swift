#if !APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
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

            let operationID = OperationID()
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
            let info = try WrapCommandSupport.wrapperInfo(
                from: snapshot,
                expectedPackageID: packageID
            )
            if json {
                try OperationCommandOutput.writeJSON(info)
            } else {
                Output.write(WrapCommandSupport.resultText(info))
            }
        }
    }

    enum WrapCommandSupport {
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
            operationID: OperationID
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
            operationID: OperationID
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
