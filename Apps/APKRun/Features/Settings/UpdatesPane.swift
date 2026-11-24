import SwiftUI

/// §9.3 Updates: the global `updates.*` keys for Android app updates.
struct UpdatesPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Check for updates") {
                    Picker(
                        "Check for updates",
                        selection: Binding(
                            get: { model.value("updates.checkIntervalHours") },
                            set: { model.set("updates.checkIntervalHours", $0) })
                    ) {
                        Text("Every hour").tag("1")
                        Text("Every 3 hours").tag("3")
                        Text("Every 6 hours").tag("6")
                        Text("Every 12 hours").tag("12")
                        Text("Every day").tag("24")
                        Text("Every 3 days").tag("72")
                        Text("Every week").tag("168")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle(
                    "Download on expensive networks",
                    isOn: binding(
                        "updates.downloadOnExpensiveNetwork", default: false))
                Toggle(
                    "Start Android to install updates",
                    isOn: binding("updates.startRuntimeToInstall", default: false))
                Toggle(
                    "Notify me after automatic updates",
                    isOn: binding("updates.notifyInstalled", default: false))
            }
            // The update source list arrives with the provider UI of #91.
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
}
