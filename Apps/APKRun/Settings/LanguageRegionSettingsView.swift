import SwiftUI

struct LanguageRegionSettingsView: View {
    @StateObject private var settings = LocaleTimeSettingsStore()

    var body: some View {
        Form {
            Section("Language & Region") {
                if settings.isLoading {
                    ProgressView()
                } else if settings.isAvailable {
                    Toggle("Use the Mac's language in Android", isOn: $settings.syncLocale)
                    Toggle("Use the Mac's time zone", isOn: $settings.syncTimeZone)
                    Toggle("Use the Mac's 12/24-hour setting", isOn: $settings.syncClockFormat)
                } else {
                    Text("These settings are temporarily unavailable.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
    }
}
