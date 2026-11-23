#if !APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Foundation
    import RuntimeAPI
    import RuntimeClient

    struct SetupCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: "Provision APKRun on this Mac (first-run setup)."
        )

        @Option(name: .long, help: "Path to a local Android image bundle folder.")
        var image: String?

        @Flag(name: .long, help: "Set up without asking for confirmation.")
        var yes = false

        mutating func run() async throws {
            try CLIConfirmation.confirm("Provision APKRun's runtime image and Android instance?", yes: yes)

            var imageSource: SetupImageSource = .feed
            if let image {
                let url = URL(fileURLWithPath: image, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else {
                    throw CLIFailure.invalidArgument(argument: "image", reason: "not a directory")
                }
                do {
                    let bookmark = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    imageSource = .directory(bookmark: bookmark)
                } catch {
                    throw CLIFailure.invalidArgument(
                        argument: "image",
                        reason: "couldn't open the folder"
                    )
                }
            }

            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }

            let operationID = RuntimeAPI.OperationID()
            let handle: OperationHandle
            do {
                handle = try await client.setup(
                    SetupRequest(image: imageSource),
                    operationID: operationID
                )
            } catch {
                throw await SetupCommandSupport.beginFailure(error, operationID: operationID)
            }

            let snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                using: client,
                operationID: handle.operationID,
                progressToStderr: OperationCommandOutput.shouldShowProgress
            )
            guard snapshot.kind == .setup else {
                throw RuntimeWireError.runtime(
                    "operationResultUnknown",
                    message: "APKRun couldn't read the result of the setup operation."
                )
            }
            try OperationCommandOutput.requireSuccess(snapshot)
            Output.write("APKRun setup is complete. Android is ready.")
        }

        enum SetupCommandSupport {
            static func beginFailure(_ error: any Error, operationID: RuntimeAPI.OperationID) async -> any Error {
                await RuntimeStatusOutput.commandFailure(error)
            }
        }
    }
#endif
