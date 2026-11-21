import AppKit
import UniformTypeIdentifiers
import RuntimeAPI
import RuntimeClient
import SwiftUI

/// The Storage pane of the Settings scene (host-ui.md §9.7).
///
/// For now it hosts **Apps with kept data**: records in
/// `uninstalledKeepingData` get **Reinstall…** (an open panel; the APK must
/// match the recorded signer) and **Delete Data**, which uninstalls without
/// `keepData` so Android drops the leftover data and the record goes.
/// The disk-usage table and Android-system rows land with #58.
struct StoragePane: View {
    @State private var keptDataApps: [RuntimePackageSummary] = []
    @State private var loadFailed = false
    @State private var busyPackageID: RuntimePackageID?
    @State private var lastError: String?

    var body: some View {
        Form {
            Section {
                if keptDataApps.isEmpty {
                    Text("No apps are keeping data.")
                        .foregroundStyle(.secondary)
                }
                ForEach(keptDataApps, id: \.packageID) { app in
                    HStack {
                        Text(app.displayName)
                        Spacer()
                        Button("Reinstall…") { reinstall(app) }
                        Button("Delete Data", role: .destructive) { deleteData(app) }
                    }
                    .disabled(busyPackageID != nil)
                }
            } header: {
                Text("Apps with kept data")
            } footer: {
                Text(
                    "Reinstalling restores the kept data when the APK comes "
                        + "from the same developer."
                )
            }
            if let lastError {
                Text(lastError)
                    .foregroundStyle(.secondary)
            }
            if loadFailed {
                Text("APKRun's background service is not running.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await reload() }
    }

    private var client: RuntimeControlClient? {
        ApprovalCenter.shared.client
    }

    private func reload() async {
        guard let client else {
            loadFailed = true
            return
        }
        do {
            let result = try await client.listPackages(filter: .managed)
            keptDataApps = result.packages.filter {
                $0.state == .uninstalledKeepingData
            }
            loadFailed = false
            lastError = nil
        } catch {
            loadFailed = true
        }
    }

    private func reinstall(_ app: RuntimePackageSummary) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false
        panel.prompt = "Reinstall"
        panel.message =
            "Choose the APK of \(app.displayName), signed by the same developer."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busyPackageID = app.packageID
        Task {
            defer { busyPackageID = nil }
            guard let client else {
                lastError = "APKRun's background service is not running."
                return
            }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let preview = try await client.importPackage(
                    RuntimeImportPackageRequest(
                        files: [RuntimeImportSourceFile(
                            fileIndex: 0,
                            name: url.lastPathComponent
                        )],
                        origin: .addFlow
                    ),
                    files: [handle]
                )
                _ = try await client.installImported(
                    RuntimeInstallImportedRequest(ticket: preview.ticket)
                )
                await reload()
            } catch {
                lastError = "Could not reinstall \(app.displayName)."
            }
        }
    }

    private func deleteData(_ app: RuntimePackageSummary) {
        busyPackageID = app.packageID
        Task {
            defer { busyPackageID = nil }
            guard let client else {
                lastError = "APKRun's background service is not running."
                return
            }
            do {
                _ = try await client.beginUninstallPackage(
                    RuntimeUninstallPackageRequest(
                        packageID: app.packageID,
                        options: RuntimeUninstallOptions(
                            keepData: false,
                            trashWrappers: false,
                            forget: false
                        )
                    ),
                    operationID: OperationID()
                )
                await reload()
            } catch {
                lastError = "Could not delete \(app.displayName)'s data."
            }
        }
    }
}
