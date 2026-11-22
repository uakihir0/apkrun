import AppKit
import SwiftUI

/// The Troubleshooting pane of the Settings scene (host-ui.md §9.8).
///
/// Shows the `apkrun doctor` health report with **Run Again**, **Deep
/// Check**, and **Fix** actions. Diagnostics bundles and **Reset Android…**
/// land with #61.
struct TroubleshootingPane: View {
    @State private var confirmDockRestart = false
    @State private var model = TroubleshootingModel()

    var body: some View {
        Form {
            Section {
                if model.rows.isEmpty, !model.isRunning, model.errorMessage == nil {
                    Text("No health report yet.")
                        .foregroundStyle(.secondary)
                }
                if !model.statusLine.isEmpty {
                    Text(model.statusLine)
                }
                ForEach(model.rows, id: \.id) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(symbol(row.state)) \(row.id) — \(row.title.fallback)")
                        if let detail = row.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                HStack {
                    Text("Health")
                    Spacer()
                    Button("Run Again") { Task { await model.check() } }
                        .disabled(model.isRunning)
                    Button("Deep Check") { Task { await model.check(deep: true) } }
                        .disabled(model.isRunning)
                    Button("Fix") { Task { await model.fix() } }
                        .disabled(model.isRunning)
                }
            } footer: {
                if model.isRunning {
                    Text("Checking…")
                }
            }

            Section {
                Button("Refresh Dock Icons…") {
                    confirmDockRestart = true
                }
            } footer: {
                Text(
                    "Restarts the Dock so Mac apps created by APKRun pick up "
                        + "their new icons."
                )
            }
        }
        .padding()
        .task { await model.check() }
        .confirmationDialog(
            "Restart the Dock?",
            isPresented: $confirmDockRestart,
            titleVisibility: .visible
        ) {
            Button("Restart Dock") { restartDock() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Dock and all of its icons restart. This cannot be undone.")
        }
    }

    private func restartDock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        try? task.run()
    }

    /// The doctor status symbol (diagnostics.md §7.3).
    private func symbol(_ state: String) -> String {
        switch state {
        case "pass": "✓"
        case "info": "ℹ"
        case "warning": "⚠"
        case "failure": "✕"
        default: "–"
        }
    }
}
