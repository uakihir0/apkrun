import Foundation
import RuntimeAPI

/// The action buttons a home row can show (host-ui.md §5.3).
enum HomeRowAction: Equatable {
    /// Row 1: Repair…
    case repair
    /// Row 3: Details
    case details
    /// Rows 4–5: Update Now
    case updateNow
    /// Row 6 `missing`: Create Mac App + Remove from List
    case createMacApp
    /// Row 6 `signatureInvalid`: Create It Again
    case createItAgain
    /// Row 6 `unknownPackage`, portable wrapper: Install from Mac App
    /// (wrapper-json.md §3.4).
    case installFromMacApp
    /// Row 6 `unknownPackage`: Move Mac App to Trash
    case trashMacApp
    /// Row 7: Update Mac App
    case updateMacApp
    /// Row 8: Open + Settings…
    case openAndSettings
}

/// The computed status line of one home row: the first matching rule of
/// host-ui.md §5.3. Pure — the T0 tests drive every row and tie.
struct HomeRowStatus: Equatable {
    /// The status line text.
    var text: String
    /// Progress for in-flight states (row 2), when the phase reports it.
    var progress: Double?
    /// The row's action buttons; empty while an operation runs.
    var actions: [HomeRowAction]
    /// Whether the app session is live (green dot + "running").
    var isRunning: Bool

    /// The first matching row of the §5.3 priority table.
    ///
    /// - Parameters:
    ///   - package: the managed package row.
    ///   - update: its `PackageUpdateStatus`, when one exists.
    ///   - lastOutcome: its newest update-history entry.
    ///   - wrapper: its `WrapperListEntryWire`, when a wrapper is registered.
    ///   - sessionPhase: its session phase, when a session exists.
    init(
        package: RuntimePackageSummary,
        update: PackageUpdateStatus?,
        lastOutcome: UpdateHistoryEntry?,
        wrapper: WrapperListEntryWire?,
        sessionPhase: WireSessionPhase?
    ) {
        isRunning = sessionPhase == .running || sessionPhase == .backgrounded
        progress = nil

        // 1. broken(reason)
        if case .broken(let reason) = package.state {
            text = "Needs attention: \(reason)"
            actions = [.repair]
            return
        }

        // 2. installing / updating(phase) / uninstalling / reinstalling
        if package.state == .installing {
            text = "Installing…"
            actions = []
            return
        }
        if package.state == .uninstalling {
            text = "Removing…"
            actions = []
            return
        }
        if let phase = update?.phase {
            switch phase {
            case .downloading(let value):
                text = "Updating…"
                progress = value
                actions = []
                return
            case .checking, .validating, .installing, .healthChecking, .rollingBack:
                text = "Updating…"
                actions = []
                return
            case .staged, .available, .completed, .unknown:
                break
            }
        }

        // 3. update failed or rolled back (update-system.md §8.3)
        if let outcome = lastOutcome, UpdatesModel.isFailed(outcome) {
            if outcome.outcome.hasPrefix("rolledBack"), let to = outcome.from {
                text = "Rolled back to \(to)"
            } else {
                text = "Update failed"
            }
            actions = [.details]
            return
        }

        // 4. update waiting (update-system.md §7.4)
        if let update, !update.waiting.isEmpty {
            if update.waiting.contains(.appInUse) {
                text = "Will update when \(package.displayName) quits"
            } else {
                text = "Update waiting"
            }
            actions = [.updateNow]
            return
        }

        // 5. update available
        if let candidate = update?.candidate {
            let version =
                candidate.versionName
                ?? candidate.versionCode.map(String.init)
                ?? ""
            text = "Update available \(version)".trimmingCharacters(in: .whitespaces)
            actions = [.updateNow]
            return
        }

        // 6. wrapper state not `valid` (wrapper.md §9.1)
        if let state = wrapper?.state {
            switch state {
            case .missing:
                text = "Mac app not found"
                actions = [.createMacApp]
                return
            case .inaccessible:
                text = "APKRun can't check this location"
                actions = []
                return
            case .signatureInvalid:
                text = "This Mac app was modified"
                actions = [.createItAgain]
                return
            case .unknownPackage:
                text = "\(package.displayName) isn't installed"
                if wrapper?.summary.kind == .portable {
                    actions = [.installFromMacApp, .trashMacApp]
                } else {
                    actions = [.trashMacApp]
                }
                return
            case .valid, .moved:
                break
            }
        }

        // 7. wrapper refresh reasons
        if let wrapper, !wrapper.refreshReasons.isEmpty {
            text = "Mac app can be updated"
            actions = [.updateMacApp]
            return
        }

        // 8. otherwise
        text = package.updateAuthority == .manual ? "Updates: Manual" : "Up to date"
        actions = [.openAndSettings]
    }
}

/// The update mode label shown under the app name (§5.3, FR-UI-04).
func updateModeLabel(for package: RuntimePackageSummary, update: PackageUpdateStatus?) -> String {
    switch package.updateAuthority {
    case .apkrun:
        switch update?.choice {
        case .notifyOnly: return "Updates: Notify only"
        case .manual: return "Updates: Manual"
        default: return "Updates: Automatic"
        }
    case .manual:
        return "Updates: Manual"
    case .googlePlay:
        return "Updates: Google Play"
    case .external:
        return "Updates: External"
    }
}
