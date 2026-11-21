import AppKit
import RuntimeAPI
import SwiftUI

@main
@MainActor
struct APKRunMenuBarApp: App {
    @StateObject private var model: MenuBarModel

    init() {
        let model = MenuBarModel()
        _model = StateObject(wrappedValue: model)
        Task { await model.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenuView(model: model)
        } label: {
            MenuBarStatusItem(
                presentation: model.snapshot.presentation(isConnected: model.isConnected)
            )
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarStatusItem: View {
    let presentation: MenuBarPresentation

    var body: some View {
        Image(systemName: presentation.androidIsActive ? "square.grid.2x2.fill" : "square.grid.2x2")
            .symbolRenderingMode(.hierarchical)
            .overlay(alignment: .topTrailing) {
                if presentation.showsAttentionDot {
                    Circle()
                        .fill(.orange)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
            }
            .accessibilityLabel(Text(runtimeLineText))
    }

    private var runtimeLineText: String {
        presentation.runtimeLine.localizedDescription
    }
}

private struct MenuBarMenuView: View {
    @ObservedObject var model: MenuBarModel

    private var presentation: MenuBarPresentation {
        model.snapshot.presentation(isConnected: model.isConnected)
    }

    var body: some View {
        Group {
            Text(runtimeLineText)
                .foregroundStyle(.secondary)

            if presentation.developerModeEnabled {
                Text("Developer mode on")
                    .foregroundStyle(.secondary)
            }

            if presentation.needsAttention {
                Button("⚠ Needs attention") {
                    openAPKRun()
                }
            }
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Section("Apps") {
                HStack {
                    Text("Running apps")
                    Spacer()
                    Text(model.snapshot.sessions.count, format: .number)
                        .foregroundStyle(.secondary)
                }

                if model.snapshot.sessions.isEmpty {
                    Text("No apps running")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.snapshot.sessions) { session in
                        Button {
                            Task { await model.launch(session) }
                        } label: {
                            Label(session.displayName, systemImage: "app")
                        }
                        .disabled(model.isPerformingAction)
                    }
                }
            }

            Section("Updates") {
                if let updates = model.snapshot.availableUpdates {
                    if updates.isEmpty {
                        Text("No updates available")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Updates are available. Open APKRun to manage updates.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Update information isn't available yet.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            runtimeAction

            Button("Open APKRun…", systemImage: "macwindow") {
                openAPKRun()
            }

            Button("Quit Menu Bar Item") {
                NSApp.terminate(nil)
            }
        }
        .confirmationDialog(
            "Stop Android?",
            isPresented: $model.isShowingStopConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Android", role: .destructive) {
                Task { await model.confirmStopAndroid() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running apps will close.")
        }
    }

    @ViewBuilder
    private var runtimeAction: some View {
        switch presentation.primaryAction {
        case .openAPKRun:
            EmptyView()
        case .startAndroid:
            Button("Start Android", systemImage: "play.fill") {
                Task { await model.startAndroid() }
            }
            .disabled(model.isPerformingAction)
        case .stopAndroid:
            Button("Stop Android", systemImage: "stop.fill") {
                Task { await model.requestStopAndroid() }
            }
            .disabled(model.isPerformingAction)
        case .none:
            EmptyView()
        }
    }

    private var runtimeLineText: String {
        presentation.runtimeLine.localizedDescription
    }

    private func openAPKRun() {
        var candidate = Bundle.main.bundleURL
        var enclosingAPKRun: URL?
        for _ in 0..<8 {
            if candidate.lastPathComponent == "APKRun.app",
                Bundle(url: candidate)?.bundleIdentifier?.hasPrefix("io.apkrun.APKRun") == true
            {
                enclosingAPKRun = candidate
                break
            }
            candidate = candidate.deletingLastPathComponent()
        }

        let bundleURL =
            enclosingAPKRun
            ?? NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "io.apkrun.APKRun.dev"
            )
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.apkrun.APKRun")
        guard let bundleURL, FileManager.default.fileExists(atPath: bundleURL.path) else { return }
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: .init())
    }
}
