import AppKit
import RuntimeAPI
import RuntimeClient
import SwiftUI
import UniformTypeIdentifiers

/// The Storage pane of the Settings scene (host-ui.md §9.7).
///
/// The **Android** rows show the current/previous/candidate images, the
/// update phase ("◐ Updating Android…" while a migration runs), Install from
/// File…, Apply, and Roll Back (runtime-maintenance.md §4.7–§4.8). The
/// **Apps with kept data** section hosts records in
/// `uninstalledKeepingData` get **Reinstall…** (an open panel; the APK must
/// match the recorded signer) and **Delete Data**, which uninstalls without
/// `keepData` so Android drops the leftover data and the record goes.
/// The disk-usage table and Android-system rows land with #58.
struct StoragePane: View {
    @State private var imageStatus: WireImageStatus?
    @State private var imageBusy = false
    @State private var keptDataApps: [RuntimePackageSummary] = []
    @State private var loadFailed = false
    @State private var busyPackageID: RuntimePackageID?
    @State private var lastError: String?

    var body: some View {
        Form {
            Section("Android") {
                if let imageStatus {
                    LabeledContent("Current", value: imageStatus.current ?? "none")
                    if let previous = imageStatus.previous {
                        LabeledContent("Previous", value: previous)
                    }
                    if case .ready(let version) = imageStatus.phase {
                        HStack {
                            Text("Ready: \(version)")
                            Spacer()
                            Button("Apply…") { applyImage(version) }
                        }
                    }
                    if case .applying(_, let to) = imageStatus.phase {
                        Text("◐ Updating Android… \(to)")
                            .foregroundStyle(.secondary)
                    }
                    if case .failed(let candidate, let reason, _) = imageStatus.phase {
                        Text("The last image update failed: \(candidate?.version ?? "unknown") (\(reason))")
                            .foregroundStyle(.red)
                    }
                    HStack {
                        Button("Install from File…") { installFromFile() }
                        Spacer()
                        if imageStatus.previous != nil {
                            Button("Roll Back…") { rollBackImage() }
                                .disabled(imageBusy)
                        }
                    }
                    if !imageStatus.recoveryPoints.isEmpty {
                        Text(
                            "\(imageStatus.recoveryPoints.count) recovery point(s) kept. Delete them with `apkrun image recovery-points delete`."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No Android image information yet.")
                        .foregroundStyle(.secondary)
                }
            }
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
            imageStatus = try? await client.imageStatus()
            loadFailed = false
            lastError = nil
        } catch {
            loadFailed = true
        }
    }

    private func installFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "aar") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imageBusy = true
        Task {
            defer { imageBusy = false }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                _ = try await client?.installImage(file: handle)
                lastError = nil
                await reload()
            } catch {
                lastError = "The image could not be installed: \(error.localizedDescription)"
            }
        }
    }

    private func applyImage(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "Apply Android image \(version)?"
        alert.informativeText =
            "Android closes while the update runs. If the new image fails its health check, "
            + "APKRun restores the previous image."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        imageBusy = true
        Task {
            defer { imageBusy = false }
            do {
                try await client?.applyImage(version: version)
                lastError = nil
                await reload()
            } catch {
                lastError = "The image could not be applied: \(error.localizedDescription)"
            }
        }
    }

    private func rollBackImage() {
        let alert = NSAlert()
        alert.messageText = "Roll back to the previous Android image?"
        alert.informativeText =
            "Android closes while the rollback runs. The current image is kept "
            + "for seven days so you can try it again."
        alert.addButton(withTitle: "Roll Back")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        imageBusy = true
        Task {
            defer { imageBusy = false }
            do {
                _ = try await client?.rollbackImage()
                lastError = nil
                await reload()
            } catch {
                lastError = "The rollback failed: \(error.localizedDescription)"
            }
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
                        files: [
                            RuntimeImportSourceFile(
                                fileIndex: 0,
                                name: url.lastPathComponent
                            )
                        ],
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
