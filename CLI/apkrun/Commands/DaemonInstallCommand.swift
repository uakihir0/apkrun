#if !APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Darwin
    import Foundation
    import RuntimeAPI
    import RuntimeClient

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

        @Flag(name: .long, help: "Return after the install operation has started.")
        var detach = false

        mutating func run() async throws {
            let urls = try DaemonInstallSupport.inputFiles(files)
            let handles = try urls.map { try DaemonInstallSupport.openRegularFile(at: $0) }
            defer {
                for handle in handles {
                    try? handle.close()
                }
            }

            let sources = urls.enumerated().map { index, url in
                RuntimeImportSourceFile(fileIndex: index, name: url.lastPathComponent)
            }
            let request = RuntimeImportPackageRequest(files: sources, origin: .cli)
            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }

            let preview: RuntimeImportPreview
            do {
                // The handles stay open through the complete daemon import and inspection request.
                preview = try await client.importPackage(request, files: handles)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }

            DaemonInstallSupport.writePreview(preview)
            if DaemonInstallSupport.requiresConfirmation {
                try CLIConfirmation.confirm(
                    DaemonInstallSupport.installConfirmationPrompt(for: preview),
                    yes: yes
                )
            }

            let installRequest = RuntimeInstallImportedRequest(
                ticket: preview.ticket,
                options: RuntimeInstallOptions()
            )

            let operationID = OperationID()
            let handle: OperationHandle
            do {
                handle = try await client.beginInstallImported(
                    installRequest,
                    operationID: operationID
                )
            } catch {
                throw await DaemonInstallSupport.installFailure(
                    error,
                    packageID: preview.packageID,
                    operationID: operationID
                )
            }

            if detach {
                if json {
                    try DaemonInstallSupport.writeJSON(handle)
                } else {
                    Output.write(
                        "Started install operation \(handle.operationID.wireValue). "
                            + "Wait with `apkrun operations wait \(handle.operationID.wireValue)`."
                    )
                }
                return
            }

            let snapshot: OperationSnapshot
            do {
                snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                    using: client,
                    operationID: handle.operationID,
                    progressToStderr: OperationCommandOutput.shouldShowProgress
                )
            } catch {
                throw await DaemonInstallSupport.installWaitFailure(
                    error,
                    packageID: preview.packageID,
                    operationID: handle.operationID
                )
            }

            let result = try OperationCommandOutput.installedPackage(
                from: snapshot,
                expectedPackageID: preview.packageID
            )

            if json {
                try DaemonInstallSupport.writeJSON(result)
            } else {
                Output.write(
                    "Installed \(DaemonInstallSupport.safeTerminalText(result.displayName)) "
                        + "(\(result.packageID.rawValue)), version "
                        + "\(result.versionCode.map(String.init) ?? "unknown")."
                )
            }
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
            help: "Forget APKRun's record and stored APKs without contacting Android."
        )
        var forget = false

        @Flag(name: .long, help: "Uninstall without asking for confirmation.")
        var yes = false

        @Flag(name: .long, help: "Return after the uninstall operation has started.")
        var detach = false

        @Flag(name: .long, help: "Print the result as JSON.")
        var json = false

        mutating func run() async throws {
            guard !forget || !keepData else {
                throw CLIFailure.invalidArgument(argument: "--keep-data", reason: "incompatibleWithForget")
            }
            guard let packageID = RuntimePackageID(rawValue: package) else {
                throw CLIFailure.invalidPackageName(package: package)
            }
            let request = RuntimeUninstallPackageRequest(
                packageID: packageID,
                options: RuntimeUninstallOptions(keepData: keepData, forget: forget)
            )
            let prompt =
                forget
                ? "Forget APKRun's record and stored APKs for \(packageID.rawValue)? "
                    + "This does not determine or change Android app data."
                : "Uninstall \(packageID.rawValue)\(keepData ? " and keep its data" : " and delete its data")?"
            try CLIConfirmation.confirm(prompt, yes: yes)

            let client: RuntimeControlClient
            do {
                client = try RuntimeControlClient(clientKind: .cli)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }

            let operationID = OperationID()
            let handle: OperationHandle
            do {
                handle = try await client.beginUninstallPackage(request, operationID: operationID)
            } catch {
                throw await DaemonInstallSupport.uninstallBeginFailure(
                    error,
                    packageID: packageID,
                    operationID: operationID
                )
            }

            if detach {
                if json {
                    try OperationCommandOutput.writeJSON(handle)
                } else {
                    Output.write(
                        "Started uninstall operation \(handle.operationID.wireValue). "
                            + "Wait with `apkrun operations wait \(handle.operationID.wireValue)`."
                    )
                }
                return
            }

            let snapshot: OperationSnapshot
            do {
                snapshot = try await OperationCommandOutput.waitForTerminalSnapshot(
                    using: client,
                    operationID: handle.operationID,
                    progressToStderr: OperationCommandOutput.shouldShowProgress
                )
            } catch {
                throw await DaemonInstallSupport.uninstallWaitFailure(
                    error,
                    packageID: packageID,
                    operationID: handle.operationID
                )
            }
            try OperationCommandOutput.requireSuccess(snapshot)
            if json {
                try OperationCommandOutput.writeJSON(snapshot)
            } else if forget {
                Output.write("Forgot \(packageID.rawValue) from APKRun.")
            } else {
                Output.write("Uninstalled \(packageID.rawValue)\(keepData ? " and kept its data" : "").")
            }
        }
    }

    enum DaemonInstallSupport {
        static let maximumInputFileCount = 20

        static func inputFiles(_ paths: [String]) throws -> [URL] {
            guard !paths.isEmpty else {
                throw CLIFailure.invalidArgument(argument: "file", reason: "required")
            }
            guard paths.count <= maximumInputFileCount else {
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
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw CLIFailure.invalidArgument(argument: "file", reason: "notRegularFile")
                }
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    throw CLIFailure.fileNotAccessible(file: url.path, .permissionDenied)
                }
                return url
            }
        }

        static func openRegularFile(at url: URL) throws -> FileHandle {
            // O_NONBLOCK lets fstat reject FIFOs without waiting for a writer.
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

        static func writePreview(_ preview: RuntimeImportPreview) {
            Output.writeLogLine(previewText(preview), toStandardError: true)
            for warning in preview.warnings {
                Output.writeLogLine("Warning: \(warningName(warning))", toStandardError: true)
            }
            if !preview.excludedSplits.isEmpty {
                let splitNames = preview.excludedSplits.map(safeTerminalText).joined(separator: ", ")
                Output.writeLogLine("Warning: Ignoring incompatible APK splits: \(splitNames)", toStandardError: true)
            }
        }

        static func previewText(_ preview: RuntimeImportPreview) -> String {
            var lines = [
                "App: \(safeTerminalText(preview.displayName))",
                "Package: \(preview.packageID.rawValue)",
                "Version: \(preview.versionName.map(safeTerminalText) ?? "unknown") (\(preview.versionCode))",
                "Relation: \(relationName(preview.relation))",
            ]
            let totalBytes = preview.files.reduce(Int64(0)) { $0 + $1.size }
            lines.append("Files (\(preview.files.count), \(totalBytes) bytes):")
            for file in preview.files {
                let split = file.splitName.map { " [\(safeTerminalText($0))]" } ?? ""
                lines.append(
                    "  \(safeTerminalText(file.name))\(split): \(file.size) bytes, \(file.sha256.rawValue)"
                )
            }
            if preview.signerDigests.isEmpty {
                lines.append("Signing: not checked")
            } else {
                let digests = preview.signerDigests.map(\.rawValue).joined(separator: ", ")
                lines.append("Signer SHA-256: \(digests)")
            }
            return lines.joined(separator: "\n")
        }

        static func safeTerminalText(_ text: String) -> String {
            let replacementCharacter = "\u{FFFD}".unicodeScalars.first
            let sanitized = text.unicodeScalars.map { scalar in
                switch scalar.value {
                case 0x0000...0x001F, 0x007F...0x009F,
                    0x061C, 0x200E, 0x200F,
                    0x2028, 0x2029,
                    0x202A...0x202E, 0x2066...0x2069:
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

        static let requiresConfirmation = true

        static func writeJSON<Value: Encodable>(_ value: Value) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(PackageInstallJSONEnvelope(result: value))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }

        static func installFailure(
            _ error: any Error,
            packageID: RuntimePackageID,
            operationID: OperationID? = nil
        ) async -> RuntimeWireError {
            if let clientError = error as? RuntimeControlClientError {
                switch clientError {
                case .operationResultUnknown:
                    return uncertainInstallResult(packageID: packageID, operationID: operationID)
                case .remoteFailure(let code, _) where code == "runtime.operationNotFound":
                    return uncertainInstallResult(packageID: packageID, operationID: operationID)
                default:
                    break
                }
            }
            if let wireError = error as? RuntimeWireError,
                wireError.code == "runtime.operationResultUnknown"
                    || wireError.code == "runtime.operationNotFound"
            {
                return uncertainInstallResult(packageID: packageID, operationID: operationID)
            }
            return await RuntimeStatusOutput.commandFailure(error)
        }

        static func installWaitFailure(
            _ error: any Error,
            packageID: RuntimePackageID,
            operationID: OperationID
        ) async -> RuntimeWireError {
            if let clientError = error as? RuntimeControlClientError {
                switch clientError {
                case .transportFailure, .requestTimedOut, .requestCancelled, .operationResultUnknown,
                    .malformedReply, .invalidRemoteProxy:
                    return uncertainInstallResult(packageID: packageID, operationID: operationID)
                case .remoteFailure(let code, _) where code == "runtime.operationNotFound":
                    return uncertainInstallResult(packageID: packageID, operationID: operationID)
                default:
                    break
                }
            }
            if let wireError = error as? RuntimeWireError,
                wireError.code == "runtime.operationResultUnknown"
                    || wireError.code == "runtime.operationNotFound"
            {
                return uncertainInstallResult(packageID: packageID, operationID: operationID)
            }
            return await RuntimeStatusOutput.commandFailure(error)
        }

        static func uninstallBeginFailure(
            _ error: any Error,
            packageID: RuntimePackageID,
            operationID: OperationID
        ) async -> RuntimeWireError {
            if isUnknownOperationResult(error) {
                return uncertainUninstallResult(packageID: packageID, operationID: operationID)
            }
            return await RuntimeStatusOutput.commandFailure(error)
        }

        static func uninstallWaitFailure(
            _ error: any Error,
            packageID: RuntimePackageID,
            operationID: OperationID
        ) async -> RuntimeWireError {
            if isUnknownOperationResult(error) {
                return uncertainUninstallResult(packageID: packageID, operationID: operationID)
            }
            if let clientError = error as? RuntimeControlClientError {
                switch clientError {
                case .transportFailure, .requestTimedOut, .requestCancelled, .malformedReply, .invalidRemoteProxy:
                    return uncertainUninstallResult(packageID: packageID, operationID: operationID)
                default:
                    break
                }
            }
            return await RuntimeStatusOutput.commandFailure(error)
        }

        private static func isUnknownOperationResult(_ error: any Error) -> Bool {
            if let clientError = error as? RuntimeControlClientError {
                switch clientError {
                case .operationResultUnknown:
                    return true
                case .remoteFailure(let code, _) where code == "runtime.operationNotFound":
                    return true
                default:
                    break
                }
            }
            if let wireError = error as? RuntimeWireError {
                return wireError.code == "runtime.operationResultUnknown"
                    || wireError.code == "runtime.operationNotFound"
            }
            return false
        }

        private static func uncertainUninstallResult(
            packageID: RuntimePackageID,
            operationID: OperationID
        ) -> RuntimeWireError {
            RuntimeWireError(
                domain: "runtime",
                code: "runtime.operationResultUnknown",
                message: "APKRun could not confirm whether the uninstall operation completed.",
                remediation:
                    "Run `apkrun operations wait \(operationID.wireValue)` to check the retained result. "
                    + "Inspect `apkrun info \(packageID.rawValue)` before retrying."
            )
        }

        private static func uncertainInstallResult(
            packageID: RuntimePackageID,
            operationID: OperationID?
        ) -> RuntimeWireError {
            let operationHint =
                operationID.map {
                    "Run `apkrun operations wait \($0.wireValue)` to check the retained operation result. "
                } ?? ""
            return RuntimeWireError(
                domain: "runtime",
                code: "runtime.operationResultUnknown",
                message: "APKRun could not confirm whether the install completed.",
                remediation: operationHint
                    + "Check `apkrun info \(packageID.rawValue)` before retrying; Android may have completed the install."
            )
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
            case .missingHardwareFeature(let feature):
                "the app requests \(safeTerminalText(feature))"
            case .certificateOnlyVerification:
                "the signing check is not complete"
            case .signingNotChecked:
                "Android will verify the APK signature during installation"
            case .debuggable:
                "the app is marked debuggable"
            case .lowTargetSDK(let target):
                "the app targets older Android API \(target)"
            }
        }
    }

    private struct PackageInstallJSONEnvelope<Value: Encodable>: Encodable {
        let schemaVersion = 1
        let result: Value
    }

#endif
