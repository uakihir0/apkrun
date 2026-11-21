import AppKit
import SwiftUI

/// §9.9 Advanced: **Developer mode** (asks for confirmation), **Install
/// Command-Line Tool…** (shows the command), and **Reveal Logs in
/// Finder**.
struct AdvancedPane: View {
    @Bindable var model: SettingsModel
    @State private var showsInstallCommand = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Developer mode",
                    isOn: Binding(
                        get: { model.flag("developer.enabled", default: false) },
                        set: { model.pickDeveloperMode($0) }))
                Text(
                    "Any local process can then reach Android over ADB at 127.0.0.1:6520. Applies the next time Android starts."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                Button("Install Command-Line Tool…") { showsInstallCommand = true }
                Button("Reveal Logs in Finder") { revealLogs() }
            }
            if let error = model.loadError {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await model.load() }
        .alert(
            "Turn on Developer mode?",
            isPresented: $model.confirmDeveloperMode
        ) {
            Button("Turn On", role: .destructive) {
                model.confirmDeveloperModeOn()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Any local process can then reach Android over ADB at 127.0.0.1:6520. It applies the next time Android starts."
            )
        }
        .alert(
            "Install Command-Line Tool",
            isPresented: $showsInstallCommand
        ) {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Self.installCommand, forType: .string)
            }
            Button("Close", role: .cancel) {}
        } message: {
            Text(
                "Run this command in Terminal to put `apkrun` on your PATH:\n\n\(Self.installCommand)"
            )
        }
    }

    /// cli.md: the symlink the installer makes; the sheet shows it so the
    /// user can run it themselves (issue #80: "shows command only").
    static let installCommand =
        "sudo ln -sf /Applications/APKRun.app/Contents/MacOS/apkrun /usr/local/bin/apkrun"

    private func revealLogs() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return }
        NSWorkspace.shared.open(library.appendingPathComponent("Logs/APKRun"))
        NSWorkspace.shared.open(directory)
    }
}
