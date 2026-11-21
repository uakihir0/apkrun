import SwiftUI

/// The Settings window's content (host-ui.md §9), in §9's tab order. The
/// Files and Language & Region panes land with their own tasks.
struct SettingsContentView: View {
    @State private var model = SettingsModel.shared

    var body: some View {
        TabView {
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gear") }
            RuntimePane(model: model)
                .tabItem { Label("Runtime", systemImage: "cpu") }
            UpdatesPane(model: model)
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
            PrivacyPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            StoragePane()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            TroubleshootingPane()
                .tabItem {
                    Label("Troubleshooting", systemImage: "wrench.and.screwdriver")
                }
            AdvancedPane(model: model)
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(minWidth: 560, minHeight: 400)
    }
}

extension APKRunApp {
    /// The Settings scene.
    var settingsScene: Settings<SettingsContentView> {
        Settings {
            SettingsContentView()
        }
    }
}
