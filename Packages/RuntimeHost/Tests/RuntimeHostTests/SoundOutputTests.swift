import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeHost

/// `audio.output` is read before every boot (configuration.md §2.4).
@Test func soundOutputProviderFollowsTheSettingsFile() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let provider = RuntimeHost.soundOutputProvider(settingsFile: paths.settingsFile)

    // A missing file is the §2.4 default: on.
    #expect(provider() == true)

    var settings = GlobalSettings()
    settings.extras["audio.output"] = "false"
    try GlobalSettings.store(settings, to: paths.settingsFile)
    #expect(provider() == false)

    // A later change is picked up at the next read — the provider is
    // re-evaluated per boot, not per daemon start.
    settings.extras["audio.output"] = "true"
    try GlobalSettings.store(settings, to: paths.settingsFile)
    #expect(provider() == true)
}
