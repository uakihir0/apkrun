import SwiftUI

/// §9.2 Runtime: `runtime.*`, `display.maxSessions`, and `audio.output`.
struct RuntimePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Start Android") {
                    Picker(
                        "Start Android",
                        selection: Binding(
                            get: { model.value("runtime.startPolicy") },
                            set: { model.set("runtime.startPolicy", $0) })
                    ) {
                        Text("When an app opens").tag("onDemand")
                        Text("When I log in").tag("atLogin")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                minutesRow(
                    "Put Android to sleep after",
                    key: "runtime.idleSuspendMinutes",
                    neverMeaning: "never put Android to sleep")
                minutesRow(
                    "Stop Android after",
                    key: "runtime.idleStopMinutes",
                    neverMeaning: "never stop Android")
                Toggle(
                    "Restart Android automatically after a crash",
                    isOn: binding("runtime.autoRestart", default: true))
            }
            Section {
                intRow(
                    "Memory", key: "runtime.memoryGiB", unit: "GiB", range: 3...128)
                intRow("Processors", key: "runtime.cpuCount", unit: "cores", range: 2...16)
                LabeledContent("Android storage") {
                    Text(
                        "\(model.value("runtime.userdataGiB")) GiB — a change applies only after Reset Android…"
                    )
                    .foregroundStyle(.secondary)
                }
                intRow(
                    "Maximum open apps", key: "display.maxSessions",
                    unit: "apps", range: 1...15)
            } footer: {
                Text("Memory and processors apply the next time Android starts.")
            }
            Section {
                Toggle("Sound output", isOn: binding("audio.output", default: true))
                Button("Restart Android Now…") {
                    model.askRestartAndroid = true
                }
                .confirmationDialog(
                    "Restart Android now?",
                    isPresented: $model.askRestartAndroid
                ) {
                    Button("Restart Android", role: .destructive) {
                        model.restartAndroid()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Running apps close while Android restarts.")
                }
            } footer: {
                Text("Sound output applies the next time Android starts.")
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

    @ViewBuilder
    private func minutesRow(_ title: String, key: String, neverMeaning _: String) -> some View {
        LabeledContent {
            HStack {
                Stepper(
                    value: Binding(
                        get: { Int(model.value(key)) ?? 0 },
                        set: { model.set(key, String($0)) }),
                    in: 0...1440
                ) {
                    Text(
                        Int(model.value(key)) == 0
                            ? "Never" : "\(model.value(key)) min")
                }
            }
        } label: {
            Text(title)
        }
    }

    @ViewBuilder
    private func intRow(
        _ title: String, key: String, unit: String, range: ClosedRange<Int>
    ) -> some View {
        LabeledContent {
            HStack {
                Stepper(
                    value: Binding(
                        get: { Int(model.value(key)) ?? range.lowerBound },
                        set: { model.set(key, String($0)) }),
                    in: range
                ) {
                    Text("\(model.value(key)) \(unit)")
                }
            }
        } label: {
            Text(title)
        }
    }
}
