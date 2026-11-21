import ServiceManagement
import SwiftUI

/// §9.1 General: the menu-bar login item, the default Mac app location,
/// and the APKRun + Android update controls (`maintenance.*`).
struct GeneralPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Show APKRun in the menu bar",
                    isOn: Binding(
                        get: { Self.menuBarEnabled },
                        set: { Self.setMenuBarEnabled($0) }))
                LabeledContent("Default location for new Mac apps") {
                    Picker(
                        "Default location",
                        selection: Binding(
                            get: { model.value("wrappers.defaultLocation") },
                            set: { model.set("wrappers.defaultLocation", $0) })
                    ) {
                        Text("Applications for me").tag("userApplications")
                        Text("Applications for all users").tag("allUsersApplications")
                        Text("Ask each time").tag("ask")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Section("Updates") {
                Toggle(
                    "Check for updates automatically",
                    isOn: binding("maintenance.checkAutomatically", default: true))
                Toggle(
                    "Install APKRun updates automatically",
                    isOn: binding(
                        "maintenance.installAPKRunAutomatically", default: false))
                LabeledContent("Android system updates") {
                    Picker(
                        "Android system updates",
                        selection: Binding(
                            get: { model.value("maintenance.installImages") },
                            set: { model.set("maintenance.installImages", $0) })
                    ) {
                        Text("Install automatically when the Mac is idle").tag("automatic")
                        Text("Ask before installing").tag("ask")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle(
                    "Download Android system updates in the background",
                    isOn: binding(
                        "maintenance.downloadImagesAutomatically", default: true))
                Toggle(
                    "Notify me when Android was updated",
                    isOn: binding(
                        "maintenance.notifyImageInstalled", default: false))
                LabeledContent("Update channel") {
                    Picker(
                        "Update channel",
                        selection: Binding(
                            get: { model.value("maintenance.channel") },
                            set: { model.set("maintenance.channel", $0) })
                    ) {
                        Text("Stable").tag("stable")
                        Text("Beta").tag("beta")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                // TODO(#58): the Check Now button and the status line wire
                // to Sparkle and the Android image channel when #58 lands.
                if let error = model.loadError {
                    Text(error).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await model.load() }
    }

    private func binding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { model.flag(key, default: defaultValue) },
            set: { model.set(key, $0 ? "true" : "false") })
    }

    /// §9.1: the menu bar item is a login item, not a settings key
    /// (configuration.md §2.10).
    private static var menuBarEnabled: Bool {
        SMAppService.loginItem(identifier: "io.apkrun.APKRunMenuBar").status
            == .enabled
    }

    private static func setMenuBarEnabled(_ enabled: Bool) {
        let item = SMAppService.loginItem(identifier: "io.apkrun.APKRunMenuBar")
        Task {
            try? await (enabled ? item.register() : item.unregister())
        }
    }
}
