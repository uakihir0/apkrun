import AppKit
import RuntimeAPI
import RuntimeClient
import SwiftUI
import UniformTypeIdentifiers

/// The main window: sidebar, runtime header, rows, and drop zone (§5).
struct HomeView: View {
    @Environment(HomeModel.self) private var model
    @Environment(RuntimeStatusModel.self) private var runtimeStatus
    @State private var search = ""
    @State private var sort: HomeSort = .name
    @State private var isDropTargeted = false
    @State private var showFilePicker = false

    var body: some View {
        NavigationSplitView {
            List(selection: Bindable(model).selection) {
                Label(HomeSection.apps.rawValue, systemImage: "square.grid.2x2")
                    .badge(model.packages.managed.count)
                    .tag(HomeSection.apps)
                Label(HomeSection.updates.rawValue, systemImage: "arrow.triangle.2.circlepath")
                    .badge(model.updates.badgeCount)
                    .tag(HomeSection.updates)
                Label(HomeSection.other.rawValue, systemImage: "app.dashed")
                    .tag(HomeSection.other)
            }
            .navigationTitle("APKRun")
            .frame(minWidth: 180)
        } detail: {
            VStack(spacing: 0) {
                RuntimeHeaderView()
                if model.serviceUnreachable { unreachableBanner }
                Divider()
                detailContent
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .toolbar {
            ToolbarItem {
                Button("Add App…", systemImage: "plus") { showFilePicker = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(HomeSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            }
            ToolbarItem {
                if !model.operations.active.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .help("\(model.operations.active.count) operation(s) running")
                }
            }
        }
        .searchable(text: $search, prompt: "Name or package ID")
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [
                UTType(filenameExtension: "apk") ?? .data,
                UTType(filenameExtension: "apks") ?? .data,
                UTType(filenameExtension: "xapk") ?? .data,
                UTType(filenameExtension: "apkm") ?? .data,
            ],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .sheet(isPresented: Bindable(model.addFlow).isPresented) {
            AddFlowView()
                .environment(model.addFlow)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                        let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async { model.importFiles([url]) }
                }
            }
            return true
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch model.selection {
        case .apps:
            AppsListView(search: search, sort: sort)
        case .updates:
            UpdatesListView()
        case .other:
            OtherAppsListView()
        }
    }

    private var unreachableBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
            Text("APKRun's background service isn't running.")
            Spacer()
            Button("Restart Service") { model.restartService() }
            Button("Troubleshooting…") {
                model.requestedSettingsPane = "troubleshooting"
            }
        }
        .padding(8)
        .background(.yellow.opacity(0.2))
    }
}

/// §5.2 runtime header.
private struct RuntimeHeaderView: View {
    @Environment(HomeModel.self) private var model
    @Environment(RuntimeStatusModel.self) private var runtimeStatus

    var body: some View {
        HStack(spacing: 12) {
            Text("Android").font(.headline)
            Text(statusText)
            Spacer()
            let running = model.sessions.runningCount
            if running > 0 {
                Text("\(running) app\(running == 1 ? "" : "s") running")
                    .foregroundStyle(.secondary)
            }
            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        guard let status = runtimeStatus.status else { return "○ Unavailable" }
        if !runtimeStatus.setupComplete { return "Setup isn't finished" }
        switch status.runtimeState {
        case "stopped": return "○ Stopped"
        case "ready": return "● Ready"
        case "stopping": return "◐ Stopping…"
        case "failed": return "⚠ Android stopped unexpectedly"
        default:
            if status.runtimeState.hasPrefix("booting") { return "◐ Starting…" }
            return "○ \(status.runtimeState)"
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let status = runtimeStatus.status, !runtimeStatus.setupComplete {
            Button("Continue Setup") {}
        } else if let status = runtimeStatus.status {
            switch status.runtimeState {
            case "stopped":
                Button("Start Android") {
                    Task { _ = try? await model.packages.requireService().startRuntime() }
                }
            case "ready":
                Button("Stop Android") {
                    Task { _ = try? await model.packages.requireService().stopRuntime() }
                }
            case "failed":
                Button("Restart") {
                    Task { _ = try? await model.packages.requireService().restartRuntime() }
                }
                Button("Troubleshooting…") {
                    model.requestedSettingsPane = "troubleshooting"
                }
            default:
                EmptyView()
            }
        }
    }
}

/// §5.3 app rows + §5.5 empty state and drop zone.
private struct AppsListView: View {
    @Environment(HomeModel.self) private var model
    let search: String
    let sort: HomeSort

    private var rows: [RuntimePackageSummary] {
        var list = model.packages.managed
        if !search.isEmpty {
            let query = search.lowercased()
            list = list.filter {
                $0.displayName.lowercased().contains(query)
                    || $0.packageID.rawValue.lowercased().contains(query)
            }
        }
        switch sort {
        case .name:
            list.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .recentlyUsed:
            let sessions = model.sessions.sessions
            list.sort { lhs, rhs in
                let li = sessions.firstIndex { $0.packageID == lhs.packageID } ?? .max
                let ri = sessions.firstIndex { $0.packageID == rhs.packageID } ?? .max
                return li == ri ? lhs.displayName < rhs.displayName : li < ri
            }
        case .recentlyUpdated:
            let updates = model.updates.updates
            list.sort { lhs, rhs in
                (updates[lhs.packageID]?.lastCheckAt ?? .distantPast)
                    > (updates[rhs.packageID]?.lastCheckAt ?? .distantPast)
            }
        }
        return list
    }

    var body: some View {
        Group {
            if rows.isEmpty && search.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(rows, id: \.packageID.rawValue) { package in
                        AppRowView(package: package)
                    }
                }
            }
        }
        .overlay {
            if let missing = model.missingPackageID {
                VStack {
                    Spacer()
                    Text("\(missing) isn't installed in APKRun.")
                        .padding(8)
                        .background(.regularMaterial, in: .capsule)
                        .padding()
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                model.missingPackageID = nil
                            }
                        }
                }
            }
        }
    }

    /// §5.5: the first-run drop zone.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Add your first Android app")
                .font(.title3)
            Text("Drag APK, APKS, or XAPK files here to add")
                .foregroundStyle(.secondary)
            Button("Add App…") {}
                .keyboardShortcut(.defaultAction)
            if let guide = URL(string: "https://github.com/uakihir0/apkrun") {
                Link("Where do I get APK files?", destination: guide)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One §5.3 app row.
private struct AppRowView: View {
    @Environment(HomeModel.self) private var model
    let package: RuntimePackageSummary

    private var status: HomeRowStatus {
        HomeRowStatus(
            package: package,
            update: model.updates.updates[package.packageID],
            lastOutcome: model.updates.lastOutcomes[package.packageID],
            wrapper: model.wrappers.entry(for: package.packageID),
            sessionPhase: model.sessions.phase(for: package.packageID)
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.displayName).font(.headline)
                    if status.isRunning {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("running").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(
                    "Android version \(package.versionName ?? "—") · "
                        + updateModeLabel(for: package, update: model.updates.updates[package.packageID])
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(status.text).font(.caption)
                    if let progress = status.progress {
                        ProgressView(value: progress).frame(width: 60)
                    }
                }
            }
            Spacer()
            actionButtons
        }
        .padding(.vertical, 4)
        .task { await model.packages.loadIcon(for: package.packageID) }
        .contextMenu {
            Button("Open") { Task { await model.packages.open(packageID: package.packageID) } }
            Button("Show Mac App in Finder") {
                if let url = model.wrappers.entry(for: package.packageID)?.summary.bundleURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("Check for Updates") {
                Task { await model.updates.checkForUpdates(packageID: package.packageID) }
            }
            Button("Settings…") {
                model.requestedSettingsPane = "general"
            }
            Divider()
            Button("Uninstall…") {}
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let png = model.packages.icon(for: package.packageID),
            let image = NSImage(data: png)
        {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(status.actions, id: \.self) { action in
            switch action {
            case .repair:
                Button("Repair…") {
                    Task { _ = try? await model.packages.requireService().repairPackage(packageID: package.packageID) }
                }
            case .details:
                Button("Details") {}
            case .updateNow:
                Button("Update Now") {
                    Task { await model.updates.updateNow(packageID: package.packageID) }
                }
            case .updateMacApp:
                Button("Update Mac App") {
                    Task { await model.wrappers.refreshWrapper(packageID: package.packageID) }
                }
            case .createMacApp, .createItAgain:
                Button(action == .createMacApp ? "Create Mac App" : "Create It Again") {
                    Task { await model.wrappers.createWrapper(packageID: package.packageID) }
                }
            case .trashMacApp:
                Button("Move Mac App to Trash") {
                    if let url = model.wrappers.entry(for: package.packageID)?.summary.bundleURL {
                        NSWorkspace.shared.recycle([url]) { _, _ in }
                    }
                }
            case .openAndSettings:
                Button("Open") {
                    Task { await model.packages.open(packageID: package.packageID) }
                }
                Button("Settings…") {
                    model.requestedSettingsPane = "general"
                }
            }
        }
    }
}

/// The Updates section (§5.1).
private struct UpdatesListView: View {
    @Environment(HomeModel.self) private var model

    var body: some View {
        let list = model.updates.updates.values.sorted {
            $0.packageID.rawValue < $1.packageID.rawValue
        }
        if list.isEmpty {
            ContentUnavailableView(
                "No updates",
                systemImage: "checkmark.circle",
                description: Text("Everything is up to date.")
            )
        } else {
            List(list, id: \.packageID.rawValue) { status in
                HStack {
                    VStack(alignment: .leading) {
                        Text(status.packageID.rawValue).font(.headline)
                        if let candidate = status.candidate {
                            Text("Update available \(candidate.versionName ?? "")")
                                .font(.caption)
                        }
                        if !status.waiting.isEmpty {
                            Text("Waiting").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if status.candidate != nil || !status.waiting.isEmpty {
                        Button("Update Now") {
                            Task { await model.updates.updateNow(packageID: status.packageID) }
                        }
                    }
                }
            }
        }
    }
}

/// §5.4 Other Android Apps.
private struct OtherAppsListView: View {
    @Environment(HomeModel.self) private var model

    var body: some View {
        let list = model.packages.other
        if list.isEmpty {
            ContentUnavailableView(
                "No other Android apps",
                systemImage: "app.dashed",
                description: Text("Apps installed outside APKRun appear here.")
            )
        } else {
            List(list, id: \.packageID.rawValue) { package in
                HStack(spacing: 12) {
                    Image(systemName: "app")
                        .frame(width: 40, height: 40)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(package.displayName).font(.headline)
                        Text("Android version \(package.versionName ?? "—")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") {
                        Task { await model.packages.open(packageID: package.packageID) }
                    }
                    Button("Manage with APKRun") {
                        Task { await model.packages.adopt(packageID: package.packageID) }
                    }
                }
            }
        }
    }
}
