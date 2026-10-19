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

            let allowDowngrade: Bool
            if case .downgrade = preview.relation {
                // A confirmed prompt or explicit --yes is the user's approval for this downgrade.
                allowDowngrade = true
            } else {
                allowDowngrade = false
            }
            let installRequest = RuntimeInstallImportedRequest(
                ticket: preview.ticket,
                options: RuntimeInstallOptions(allowDowngrade: allowDowngrade)
            )

            let result: RuntimePackageSummary
            do {
                // Do not retry this request after a transport failure: Android may have completed it.
                result = try await client.installImported(installRequest)
            } catch {
                throw await DaemonInstallSupport.installFailure(
                    error,
                    packageID: preview.packageID
                )
            }

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
            if case .downgrade(let fromVersion) = preview.relation {
                Output.writeLogLine(
                    "Warning: This downgrade replaces version \(fromVersion); it will work only on a debuggable Android image.",
                    toStandardError: true
                )
            }
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
                return "Downgrade \(displayName) (\(packageID)) from version \(fromVersion) "
                    + "to version \(preview.versionCode)? This requires a debuggable Android image."
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
            packageID: RuntimePackageID
        ) async -> RuntimeWireError {
            if let clientError = error as? RuntimeControlClientError {
                switch clientError {
                case .operationResultUnknown, .requestTimedOut, .requestCancelled:
                    return RuntimeWireError(
                        domain: "runtime",
                        code: clientError.codeForInstallFailure,
                        message: "APKRun could not confirm whether the install completed.",
                        remediation:
                            "Check `apkrun info \(packageID.rawValue)` before retrying; Android may have completed the install."
                    )
                default:
                    break
                }
            }
            return await RuntimeStatusOutput.commandFailure(error)
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

    extension RuntimeControlClientError {
        fileprivate var codeForInstallFailure: String {
            switch self {
            case .requestTimedOut:
                "runtime.operationResultUnknown"
            case .operationResultUnknown:
                "runtime.operationResultUnknown"
            case .requestCancelled:
                "runtime.operationResultUnknown"
            case .transportFailure:
                "runtime.serviceUnavailable"
            default:
                "runtime.internal"
            }
        }
    }
#endif
