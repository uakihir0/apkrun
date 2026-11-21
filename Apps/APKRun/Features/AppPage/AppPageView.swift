import RuntimeAPI
import SwiftUI

/// The app page — a package's detail view and per-app settings
/// (host-ui.md §7). Reached from a row's **Settings…**, the `Details`
/// button, and `apkrun://package/<id>/<section>`.
struct AppPageView: View {
    @State private var model: PackageDetailModel

    init(model: PackageDetailModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Section", selection: $model.section) {
                ForEach(PackageDetailModel.PageSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            Form {
                if let error = model.loadError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                }
                sectionContent
            }
            .formStyle(.grouped)
        }
        .navigationTitle(model.displayName)
        .task { await model.load() }
        .confirmationDialog(
            "APKRun will stop updating \(model.displayName). An app store inside Android can update it instead.",
            isPresented: $model.confirmExternalAuthority,
            titleVisibility: .visible
        ) {
            Button("Let an Android Store Update It", role: .destructive) {
                model.confirmExternal()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Roll back \(model.displayName) to the previous version?",
            isPresented: $model.confirmRollback,
            titleVisibility: .visible
        ) {
            Button("Roll Back", role: .destructive) { model.rollback() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $model.showsUninstall) {
            UninstallDialog(
                displayName: model.displayName,
                hasWrapper: model.wrapper != nil,
                appIsOpen: model.running,
                runtimeUnavailable: false,
                onUninstall: { model.uninstall($0.options) },
                onCancel: { model.showsUninstall = false }
            )
            .padding(20)
            .frame(width: 420)
        }
        .sheet(isPresented: $model.showsRepair) {
            RepairSheet(
                displayName: model.displayName,
                brokenReason: brokenReasonText,
                onRepair: { model.repair() },
                onRemove: { model.forget() },
                onCancel: { model.showsRepair = false }
            )
            .padding(20)
            .frame(width: 420)
        }
    }

    /// The `broken` reason §7.7's Repair… passes to the sheet.
    private var brokenReasonText: String {
        if case .broken(let reason) = model.details?.summary.state {
            return reason
        }
        return "broken"
    }

    /// §7 header: icon, name, version, running state, actions, … menu.
    private var header: some View {
        HStack(spacing: 12) {
            if let data = model.icon, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .frame(width: 48, height: 48)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.title2).fontWeight(.semibold)
                HStack(spacing: 8) {
                    if let version = model.details?.summary.versionName {
                        Text(version)
                    }
                    if let code = model.details?.summary.versionCode {
                        Text("(\(code))")
                    }
                    if model.running {
                        Label("Running", systemImage: "circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { model.open() }
                .keyboardShortcut(.defaultAction)
            if model.updateStatus?.candidate != nil {
                Button("Update Now") { model.updateNow() }
            }
            Menu {
                Button("Show Mac App in Finder") {
                    if let url = model.wrapper?.summary.bundleURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .disabled(model.wrapper == nil)
                Button("Check for Updates") { model.checkNow() }
                Button("Repair…") { model.showsRepair = true }
                Divider()
                Button("Uninstall…", role: .destructive) { model.showsUninstall = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.section {
        case .general:
            GeneralSection(model: model)
        case .window:
            WindowSection(model: model)
        case .input:
            InputSection(model: model)
        case .integrations:
            IntegrationsSection(model: model)
        case .updates:
            UpdatesSection(model: model)
        case .macApp:
            MacAppSection(
                packageID: model.packageID,
                entry: model.wrapper,
                onShowInFinder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                onRefresh: { model.refreshWrapper() },
                onCreate: { model.createWrapper() },
                onRemove: { model.removeWrapper() })
        case .storage:
            StorageSection(model: model)
        }
    }
}

/// Shared row helpers of §7: a "Recommended for this app" marker and a
/// **Reset** that clears the stored value.
extension PackageDetailModel {
    /// The footnote §7 shows under a next-session key after a write.
    var nextOpenNote: String? {
        appliesNextOpenNotice ? "Applies the next time \(displayName) opens." : nil
    }
}

/// A setting row's trailing accessories: the recommended marker and Reset.
struct SettingAccessories: View {
    let key: String
    @Bindable var model: PackageDetailModel

    var body: some View {
        if model.isRecommended(key) {
            Text("Recommended for this app")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if model.isCustomized(key) {
            Button("Reset") { model.reset(key) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}
