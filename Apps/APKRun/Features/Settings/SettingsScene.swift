import SwiftUI

/// The Settings window's content (host-ui.md §9). The General, Runtime,
/// Updates, Files, Language & Region, and Advanced panes land with #80 and
/// #58.
struct SettingsContentView: View {
    var body: some View {
        TabView {
            PrivacyPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            StoragePane()
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            TroubleshootingPane()
                .tabItem {
                    Label("Troubleshooting", systemImage: "wrench.and.screwdriver")
                }
        }
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
