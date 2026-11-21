import Foundation
import RuntimeAPI
import RuntimeClient

/// The `maintenance.*` → Sparkle mapping (runtime-maintenance.md §3.2's
/// source-of-truth paragraph). Pure so the unit-test target checks it
/// without Sparkle.
struct SelfUpdateSettings: Equatable, Sendable {
    /// `updater.automaticallyChecksForUpdates`.
    var checkAutomatically = true
    /// `updater.automaticallyDownloadsUpdates`.
    var downloadAutomatically = false
    /// `maintenance.channel`; `"beta"` allows beta appcast items.
    var channel = "stable"

    init(values: [String: String]) {
        if let raw = values["maintenance.checkAutomatically"], !raw.isEmpty {
            checkAutomatically = raw == "true"
        }
        downloadAutomatically = values["maintenance.installAPKRunAutomatically"] == "true"
        if let channel = values["maintenance.channel"], !channel.isEmpty {
            self.channel = channel
        }
    }

    /// `allowedChannels(for:)` (§3.2's delegate table).
    var allowedChannels: Set<String> {
        channel == "beta" ? ["beta"] : []
    }
}

/// What the Settings General pane shows about self-updates (§3.2's status
/// line; host-ui.md §9.1).
@Observable
@MainActor
final class SelfUpdateModel {
    /// The newest release the last check accepted.
    private(set) var latest: AvailableRelease?
    /// When the last check finished.
    private(set) var lastCheckedAt: Date?
    /// The update Sparkle installs on quit.
    private(set) var pendingRelease: AvailableRelease?
    /// Set by `willInstallUpdateOnQuit`: runs the §3.5 handshake and installs
    /// at once (the "Install and Relaunch Now" button).
    var installNowHandler: (() -> Void)?

    func foundUpdate(_ release: AvailableRelease) {
        latest = release
        lastCheckedAt = Date()
    }

    func checked(found: AvailableRelease?) {
        latest = found
        lastCheckedAt = Date()
    }

    func pendingOnQuit(_ release: AvailableRelease) {
        pendingRelease = release
        latest = release
        lastCheckedAt = Date()
    }

    /// The status line's text (§3.2).
    var statusLine: String {
        if let pendingRelease {
            return "APKRun \(pendingRelease.version) will be installed when you quit APKRun."
        }
        if let latest {
            return "APKRun \(latest.version) is available."
        }
        if lastCheckedAt != nil {
            return "APKRun is up to date."
        }
        return ""
    }
}
