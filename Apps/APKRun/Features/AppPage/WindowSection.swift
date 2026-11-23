import RuntimeAPI
import SwiftUI

/// §7.2 Window: size, resizable, always-on-top, zoom, close behavior and
/// the display mode.
struct WindowSection: View {
    @Bindable var model: PackageDetailModel
    @State private var width = ""
    @State private var height = ""

    var body: some View {
        Section("Window") {
            HStack {
                Text("Default size")
                Spacer()
                TextField("Width", text: $width)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { commitSize() }
                Text("×")
                TextField("Height", text: $height)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { commitSize() }
                Text("pt").foregroundStyle(.secondary)
                SettingAccessories(key: "window.defaultWidth", model: model)
            }
            row("Resizable", key: "window.resizable")
            row("Always on top", key: "window.alwaysOnTop") {
                Text("No effect in full screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(model.value("window.zoom")) ?? 1.0 },
                            set: { model.set("window.zoom", Self.zoomText($0)) }),
                        in: 0.75...2.0, step: 0.05)
                    Text("\(Int(((Double(model.value("window.zoom")) ?? 1.0) * 100).rounded()))%")
                        .frame(width: 44, alignment: .trailing)
                    SettingAccessories(key: "window.zoom", model: model)
                }
            } label: {
                Text("Zoom")
            }
            picker(
                "When I close the window", key: "window.closeBehavior",
                choices: [
                    ("stop", "Quit the app"),
                    ("keepRunning", "Keep it running in the background"),
                ])
            picker(
                "Window mode", key: "window.mode",
                choices: [
                    ("secondaryDisplay", "Standard"),
                    ("primaryDisplayCompatibility", "Compatibility"),
                ])
        }
        .onAppear {
            width = model.value("window.defaultWidth")
            height = model.value("window.defaultHeight")
        }
        .onChange(of: model.settings) {
            if width.isEmpty { width = model.value("window.defaultWidth") }
            if height.isEmpty { height = model.value("window.defaultHeight") }
        }
    }

    private func commitSize() {
        if let w = Int(width), (320...8192).contains(w) {
            model.set("window.defaultWidth", String(w))
        } else {
            width = model.value("window.defaultWidth")
        }
        if let h = Int(height), (400...8192).contains(h) {
            model.set("window.defaultHeight", String(h))
        } else {
            height = model.value("window.defaultHeight")
        }
    }

    private static func zoomText(_ zoom: Double) -> String {
        String(format: "%.2f", zoom)
    }

    @ViewBuilder
    private func row(
        _ title: String, key: String,
        footnote: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(
                title,
                isOn: Binding(
                    get: { model.value(key) == "true" },
                    set: { model.set(key, $0 ? "true" : "false") }))
            footnote()
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
            if let note = model.nextOpenNote,
                ["window.mode", "window.defaultWidth", "window.defaultHeight"].contains(key)
            {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
