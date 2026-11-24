import Foundation
import RuntimeAPI
import RuntimeClient

/// The Settings window's model (host-ui.md §9): the `settings.json` keys
/// the panes edit, read and written through `getConfig`/`setConfig`.
@Observable
@MainActor
final class SettingsModel {
    static let shared = SettingsModel()

    private(set) var values: [String: String] = [:]
    private(set) var loadError: String?
    /// The Advanced pane's Developer mode confirmation (§9.9).
    var confirmDeveloperMode = false
    /// The Runtime pane's restart confirmation (§9.2).
    var askRestartAndroid = false

    private let makeService: @Sendable () throws -> any RuntimeService

    init(
        makeService: @escaping @Sendable () throws -> any RuntimeService = {
            try RuntimeControlClient(clientKind: .app)
        }
    ) {
        self.makeService = makeService
    }

    func load() async {
        do {
            values = try await makeService().getConfig(keys: nil)
            loadError = nil
        } catch {
            loadError = PackageDetailModel.describe(error)
        }
    }

    /// The effective value of a key ("" before `load` finishes).
    func value(_ key: String) -> String {
        values[key] ?? ""
    }

    /// A bool key for a `Toggle` (configuration.md §2's `bool` keys).
    func flag(_ key: String, default defaultValue: Bool) -> Bool {
        value(key) == "true" || (value(key).isEmpty && defaultValue)
    }

    /// Writes one key at once, like the app page's controls (§7).
    func set(_ key: String, _ newValue: String) {
        Task {
            do {
                values = try await makeService().setConfig(key: key, value: newValue)
                loadError = nil
            } catch {
                loadError = PackageDetailModel.describe(error)
            }
        }
    }

    /// **Developer mode** asks for confirmation before turning on (§9.9);
    /// turning off does not.
    func pickDeveloperMode(_ on: Bool) {
        if on, !flag("developer.enabled", default: false) {
            confirmDeveloperMode = true
            return
        }
        set("developer.enabled", on ? "true" : "false")
    }

    func confirmDeveloperModeOn() {
        confirmDeveloperMode = false
        set("developer.enabled", "true")
    }

    /// Restarts Android so restart-applied keys like `audio.output` take
    /// effect (§9.2's **Restart Android Now**).
    func restartAndroid() {
        Task {
            do {
                _ = try await makeService().restartRuntime()
            } catch {
                loadError = PackageDetailModel.describe(error)
            }
        }
    }

    /// Testing seam.
    func injectValues(_ newValues: [String: String]) {
        values = newValues
    }
}
