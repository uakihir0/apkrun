import SwiftUI

extension APKRunApp {
    /// The Settings scene. Only the Privacy pane exists for now; #80 adds the
    /// rest (host-ui.md §9.4).
    var settingsScene: Settings<PrivacyPane> {
        Settings {
            PrivacyPane()
        }
    }
}
