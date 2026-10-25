import AppKit
import Darwin
import Observation
import RuntimeAPI
import RuntimeClient
import SwiftUI

struct SharedFoldersSettingsView: View {
    @State private var model = SharedFoldersSettingsModel()

    var body: some View {
        Form {
            Section {
                if model.isLoading && model.folders.isEmpty {
                    ProgressView("Loading shared folders…")
                } else if model.folders.isEmpty {
                    Text("No shared folders are configured.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.folders, id: \.id) { folder in
                        SharedFolderRow(
                            folder: folder,
                            setAccess: { access in
                                Task { await model.setAccess(access, for: folder) }
                            },
                            remove: {
                                Task { await model.remove(folder) }
                            },
                            showInFinder: {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: folder.path)
                                ])
                            }
                        )
                    }
                }
            } header: {
                Text("Shared folders")
            } footer: {
                Text(
                    "Android apps can only access folders you add here and only when their shared-folder access is enabled. "
                        + "Read and write lets apps change files in that folder."
                )
            }

            HStack {
                Button("Add Folder…") {
                    model.addFolder()
                }
                .disabled(model.isWorking)

                Spacer()

                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh shared folders")
                .disabled(model.isLoading || model.isWorking)
            }

            if let errorMessage = model.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 400)
        .task {
            await model.reload()
        }
    }
}

private struct SharedFolderRow: View {
    let folder: SharedFolder
    let setAccess: (SharedFolderAccess) -> Void
    let remove: () -> Void
    let showInFinder: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: folder.builtIn ? "folder.badge.gearshape" : "folder")
                .frame(width: 20)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(folder.name)
                        .fontWeight(.medium)
                    if folder.builtIn {
                        Text("APKRun Shared")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if folder.availability != .available {
                    Label(availabilityMessage, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 12)

            if folder.builtIn {
                Button("Show in Finder", action: showInFinder)
                    .controlSize(.small)
            } else {
                Picker(
                    "Access",
                    selection: Binding(
                        get: { folder.access },
                        set: setAccess
                    )
                ) {
                    Text("Read only").tag(SharedFolderAccess.readOnly)
                    Text("Read and write").tag(SharedFolderAccess.readWrite)
                }
                .labelsHidden()
                .frame(width: 150)

                Button("Remove", role: .destructive, action: remove)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }

    private var availabilityMessage: String {
        switch folder.availability {
        case .available:
            "Available"
        case .missing:
            "Can't access. Put the folder back or remove it."
        case .privacyDenied:
            "Can't access. Allow APKRun in System Settings → Privacy & Security → Files and Folders."
        case .offline:
            "Can't access. Connect the drive or network volume."
        case .unknown:
            "APKRun couldn't check this folder."
        }
    }
}

@MainActor
@Observable
private final class SharedFoldersSettingsModel {
    private let client: RuntimeControlClient?
    private(set) var folders: [SharedFolder] = []
    private(set) var isLoading = false
    private(set) var isWorking = false
    var errorMessage: String?

    init() {
        do {
            client = try RuntimeControlClient(clientKind: .app)
        } catch {
            client = nil
            errorMessage = error.localizedDescription
        }
    }

    func reload() async {
        guard let client else { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            folders = try await client.sharedFolders().sorted {
                $0.builtIn && !$1.builtIn
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "Add a Shared Folder"
        panel.prompt = "Share Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: url])
            }
            _ = Darwin.close(descriptor)
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            guard let client else {
                errorMessage = "APKRun's background service isn't running."
                return
            }
            isWorking = true
            Task {
                defer { isWorking = false }
                do {
                    _ = try await client.addSharedFolder(AddSharedFolderRequest(bookmark: bookmark))
                    await reload()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setAccess(_ access: SharedFolderAccess, for folder: SharedFolder) async {
        guard let client, !folder.builtIn else { return }
        await performChange {
            _ = try await client.setSharedFolderAccess(id: folder.id, access: access)
        }
    }

    func remove(_ folder: SharedFolder) async {
        guard let client, !folder.builtIn else { return }
        await performChange {
            _ = try await client.removeSharedFolder(id: folder.id)
        }
    }

    private func performChange(_ operation: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            try await operation()
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
