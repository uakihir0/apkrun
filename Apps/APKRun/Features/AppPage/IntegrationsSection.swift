import RuntimeAPI
import SwiftUI

/// §7.4 Integrations: the desktop-integration.md §2.1 keys plus the live
/// `integrationStatus` report for each.
struct IntegrationsSection: View {
    @Bindable var model: PackageDetailModel

    var body: some View {
        Section("Integrations") {
            toggle(
                "Clipboard", key: "integrations.clipboard", kind: "clipboard",
                footnote: "Android shares one clipboard among its apps.")
            toggle(
                "Notifications", key: "integrations.notifications",
                kind: "notifications",
                footnote: model.value("window.closeBehavior") == "stop"
                    ? "\(model.displayName) can only notify you while it is running."
                    : nil)
            picker(
                "Links", key: "integrations.links",
                choices: [
                    ("ask", "Ask"),
                    ("mac", "Open in Mac browser"),
                    ("android", "Open in Android"),
                ])
            toggle(
                "Files", key: "integrations.files", kind: "files",
                footnote:
                    "Drag files into \(model.displayName), and save files from \(model.displayName) to your Mac."
            )
            picker(
                "Shared folders", key: "integrations.sharedFolders",
                choices: [
                    ("off", "Off"),
                    ("readOnly", "Read only"),
                    ("readWrite", "Read and write"),
                ])
            toggle(
                "Microphone", key: "integrations.microphone", kind: "microphone",
                footnote: model.integrations?.microphoneNeedsRestart == true
                    ? "Android needs to restart to change the microphone."
                    : nil)
            LabeledContent("Camera") {
                Text("Not supported yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The §7.4 status line of one integration, when `integrationStatus`
    /// reports one: the image's support, the Settings → Privacy global
    /// switch, or the macOS permission state.
    private func statusNote(_ kind: String) -> String? {
        guard
            let item = model.integrations?.items.first(where: {
                $0.kind.rawValue == kind
            })
        else { return nil }
        if item.support == .unsupported {
            return "Not available with this Android image."
        }
        if item.source == .globalSwitch {
            return "Turned off for all apps in Settings → Privacy."
        }
        if let permission = item.macPermission {
            return permission
        }
        return nil
    }

    @ViewBuilder
    private func toggle(
        _ title: String, key: String, kind: String, footnote: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                title,
                isOn: Binding(
                    get: { model.value(key) == "true" },
                    set: { model.set(key, $0 ? "true" : "false") }))
            if let note = statusNote(kind) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
            if model.isRecommended(key) || model.isCustomized(key) {
                SettingAccessories(key: key, model: model)
            }
        }
    }

    @ViewBuilder
    private func picker(
        _ title: String, key: String, choices: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent {
                HStack {
                    Picker(
                        title,
                        selection: Binding(
                            get: { model.value(key) },
                            set: { model.set(key, $0) })
                    ) {
                        ForEach(choices, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    SettingAccessories(key: key, model: model)
                }
            } label: {
                Text(title)
            }
            if let note = statusNote(key.replacingOccurrences(of: "integrations.", with: "")) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
