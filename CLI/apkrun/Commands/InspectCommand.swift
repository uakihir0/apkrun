#if !APKRUN_EMBEDDED_RUNTIME
    import ArgumentParser
    import Darwin
    import Foundation
    import RuntimeAPI
    import RuntimeClient

    /// `apkrun inspect <file>… [--json]` — host inspection only; never starts Android
    /// (package-store.md §4, runtime-api.md §10).
    struct InspectCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "inspect",
            abstract: "Inspect an APK, split set, or container without installing."
        )

        @Argument(help: "APK files, or one .apks/.xapk/.apkm container.")
        var files: [String]

        @Flag(name: .long, help: "Print the inspection result as JSON.")
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
                preview = try await client.importPackage(request, files: handles)
            } catch {
                throw await RuntimeStatusOutput.commandFailure(error)
            }

            if json {
                try DaemonInstallSupport.writeJSON(preview)
            } else {
                Output.write(DaemonInstallSupport.previewText(preview))
                for warning in preview.warnings {
                    Output.writeLogLine(
                        "Warning: \(warningText(warning))",
                        toStandardError: true
                    )
                }
                if !preview.excludedSplits.isEmpty {
                    let names = preview.excludedSplits
                        .map(DaemonInstallSupport.safeTerminalText)
                        .joined(separator: ", ")
                    Output.writeLogLine(
                        "Excluded splits: \(names)",
                        toStandardError: true
                    )
                }
            }

            // The preview ticket is deleted once the result is printed.
            do {
                try await client.discardImport(RuntimeDiscardImportRequest(ticket: preview.ticket))
            } catch {
                Output.writeLogLine(
                    "Warning: the inspection ticket could not be discarded.",
                    toStandardError: true
                )
            }
        }

        private func warningText(_ warning: RuntimeImportWarning) -> String {
            switch warning {
            case .missingHardwareFeature(let feature):
                "the app requests \(DaemonInstallSupport.safeTerminalText(feature))"
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
#endif
