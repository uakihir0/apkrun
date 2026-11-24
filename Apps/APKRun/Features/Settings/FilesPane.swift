import RuntimeAPI
import RuntimeClient
import SwiftUI

/// The Files pane (host-ui.md §9.5): the shared-folder list of
/// desktop-integration.md §6.4. The built-in APKRun Shared folder comes first
/// with "Show in Finder"; user folders show their maximum access and
/// availability. Add goes through an open panel whose result becomes a
/// security-scoped bookmark for `addSharedFolder`.
struct FilesPane: View {
    @State private var model = FilesPaneModel()

    var body: some View {
        Form {
            Section("Shared folders") {
                if model.folders.isEmpty && !model.loading {
                    Text("Only the built-in Shared folder is available.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.folders, id: \.id) { folder in
                    row(folder)
                }
                Button("Add Folder…") { model.pickFolder() }
            }
            if let error = model.loadError {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
    }

    @ViewBuilder
    private func row(_ folder: SharedFolder) -> some View {
        LabeledContent {
            HStack {
                if folder.builtIn {
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: folder.path))
                    }
                } else {
                    Picker(
                        "Access",
                        selection: Binding(
                            get: { folder.access },
                            set: { newValue in
                                Task {
                                    await model.setAccess(
                                        folder.id, access: newValue)
                                }
                            })
                    ) {
                        Text("Read only").tag("readOnly")
                        Text("Read and write").tag("readWrite")
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Remove") {
                        Task { await model.remove(folder.id) }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                if !folder.builtIn {
                    Text(folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if folder.availability != "available" {
                    Text(
                        "Can't access. Allow APKRun in System Settings → Privacy & Security → Files and Folders."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

}

/// The pane's model: loads `sharedFolders()` and applies edits through the
/// dedicated shared-folder operations (configuration.md §2.2).
@Observable
@MainActor
final class FilesPaneModel {
    private(set) var folders: [SharedFolder] = []
    private(set) var loading = false
    var loadError: String?

    private let makeClient: @Sendable () throws -> RuntimeControlClient

    init(
        makeClient: @escaping @Sendable () throws -> RuntimeControlClient = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        self.makeClient = makeClient
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await makeClient().sharedFolders()
            // The built-in Shared folder sorts first (§9.5).
            folders = list.sorted { $0.builtIn && !$1.builtIn }
            loadError = nil
        } catch {
            loadError = PackageDetailModel.describe(error)
        }
    }

    /// Opens a folder panel and adds the pick as a shared root.
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Share"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await add(url: url, access: "readOnly") }
    }

    func add(url: URL, access: String) async {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            _ = try await makeClient().addSharedFolder(bookmark: bookmark, access: access)
            await load()
        } catch {
            loadError = PackageDetailModel.describe(error)
        }
    }

    func remove(_ id: String) async {
        do {
            try await makeClient().removeSharedFolder(id: id)
            await load()
        } catch {
            loadError = PackageDetailModel.describe(error)
        }
    }

    func setAccess(_ id: String, access: String) async {
        do {
            _ = try await makeClient().setSharedFolderAccess(id: id, access: access)
            await load()
        } catch {
            loadError = PackageDetailModel.describe(error)
        }
    }
}
