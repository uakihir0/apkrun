import AppKit
import SwiftUI

/// The Troubleshooting pane of the Settings scene (host-ui.md §9.8).
///
/// Only **Refresh Dock Icons** is in scope here (wrapper.md §8.5): it
/// restarts the Dock after a confirmation and is never run automatically.
/// The `apkrun doctor` report, diagnostics bundles, graphics safe mode, and
/// **Reset Android…** land with #60 and #58.
struct TroubleshootingPane: View {
    @State private var confirmDockRestart = false

    var body: some View {
        Form {
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
}
