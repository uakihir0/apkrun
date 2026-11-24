import RuntimeAPI
import SwiftUI

/// §7.3 Input: the input.md §4–§5 keys. Every one applies at the next
/// session, so the section keeps a permanent note.
struct InputSection: View {
    @Bindable var model: PackageDetailModel

    var body: some View {
        Section {
            picker(
                "Esc key", key: "input.escapeKey",
                choices: [("back", "Back"), ("escape", "Escape")])
            picker(
                "Right click", key: "input.secondaryClick",
                choices: [
                    ("mouseSecondary", "Mouse right click"),
                    ("longPress", "Long press"),
                ])
            picker(
                "Scrolling", key: "input.scrollMode",
                choices: [("scroll", "Scroll"), ("touchDrag", "Touch drag")])
            toggle("Mouse hover", key: "input.hover")
            toggle("Send the Command key to the app", key: "input.sendCommandKey")
        } header: {
            Text("Input")
        } footer: {
            Text("Input changes apply the next time \(model.displayName) opens.")
        }
    }

    @ViewBuilder
    private func toggle(_ title: String, key: String) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { model.value(key) == "true" },
                set: { model.set(key, $0 ? "true" : "false") }))
        if model.isRecommended(key) || model.isCustomized(key) {
            SettingAccessories(key: key, model: model)
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
        }
    }
}
