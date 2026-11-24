import Foundation
import RuntimeAPI

struct MenuBarSession: Equatable, Identifiable, Sendable {
    let id: String
    let packageID: String
    let displayName: String
}

struct MenuBarUpdate: Equatable, Identifiable, Sendable {
    let packageID: String
    let displayName: String
    let versionName: String

    var id: String { packageID }

    init(packageID: String, displayName: String, versionName: String) {
        self.packageID = packageID
        self.displayName = displayName
        self.versionName = versionName
    }
}

struct MenuBarSnapshot: Equatable, Sendable {
    let runtimeStatus: RuntimeHostStatus?
    let sessions: [MenuBarSession]
    let hasOpenSessions: Bool
    /// `nil` means the update service is not available. An empty list means there are no updates.
    let availableUpdates: [MenuBarUpdate]?
    /// `nil` means the daemon does not expose a live health snapshot yet.
    let liveHealthNeedsAttention: Bool?
    /// `nil` means developer mode is not available from the daemon snapshot.
    let developerModeEnabled: Bool?

    init(
        runtimeStatus: RuntimeHostStatus?,
        sessions: [MenuBarSession] = [],
        hasOpenSessions: Bool? = nil,
        availableUpdates: [MenuBarUpdate]? = nil,
        liveHealthNeedsAttention: Bool? = nil,
        developerModeEnabled: Bool? = nil
    ) {
        self.runtimeStatus = runtimeStatus
        self.sessions = sessions
        self.hasOpenSessions = hasOpenSessions ?? !sessions.isEmpty
        self.availableUpdates = availableUpdates
        self.liveHealthNeedsAttention = liveHealthNeedsAttention
        self.developerModeEnabled = developerModeEnabled
    }

    func presentation(isConnected: Bool) -> MenuBarPresentation {
        guard isConnected, let runtimeStatus else {
            return MenuBarPresentation(
                runtimeLine: .unreachable,
                androidIsActive: false,
                needsAttention: false,
                showsAttentionDot: false,
                developerModeEnabled: false
            )
        }

        let runtimeLine = Self.runtimeLine(for: runtimeStatus)
        let isFailed = runtimeLine == .failed
        let hasHealthIssue =
            (liveHealthNeedsAttention ?? false) || runtimeStatus.hostState == "degraded"
        let needsAttention = isFailed || hasHealthIssue || runtimeStatus.startupFailureCode != nil
        let hasUpdates = availableUpdates?.isEmpty == false

        return MenuBarPresentation(
            runtimeLine: runtimeLine,
            androidIsActive: Self.androidIsActive(runtimeStatus.runtimeState),
            needsAttention: needsAttention,
            showsAttentionDot: hasUpdates || needsAttention,
            developerModeEnabled: developerModeEnabled ?? false
        )
    }

    private static func runtimeLine(for status: RuntimeHostStatus) -> MenuBarRuntimeLine {
        let runtimeState = status.runtimeState
        if status.hostState == "starting" || runtimeState.hasPrefix("booting") {
            return .starting
        }
        if runtimeState == "ready" {
            return .ready
        }
        if runtimeState == "suspended" || runtimeState == "asleep" {
            return .sleeping
        }
        if runtimeState == "stopping" {
            return .stopping
        }
        if runtimeState == "failed" {
            return .failed
        }
        if runtimeState == "stopped" {
            return .stopped
        }
        return .unknown
    }

    private static func androidIsActive(_ runtimeState: String) -> Bool {
        runtimeState == "ready"
            || runtimeState == "stopping"
            || runtimeState.hasPrefix("booting")
    }
}

enum MenuBarRuntimeLine: Equatable, Sendable {
    case unreachable
    case starting
    case ready
    case sleeping
    case stopping
    case stopped
    case failed
    case unknown

    var localizedDescription: String {
        switch self {
        case .unreachable:
            String(localized: "APKRun background service isn't running")
        case .starting:
            String(localized: "Starting Android…")
        case .ready:
            String(localized: "Android is running")
        case .sleeping:
            String(localized: "Android is asleep")
        case .stopping:
            String(localized: "Stopping Android…")
        case .stopped:
            String(localized: "Android is stopped")
        case .failed:
            String(localized: "Android stopped unexpectedly")
        case .unknown:
            String(localized: "Android status is unknown")
        }
    }
}

struct MenuBarPresentation: Equatable, Sendable {
    let runtimeLine: MenuBarRuntimeLine
    let androidIsActive: Bool
    let needsAttention: Bool
    let showsAttentionDot: Bool
    let developerModeEnabled: Bool

    var primaryAction: MenuBarPrimaryAction {
        switch runtimeLine {
        case .unreachable:
            .openAPKRun
        case .stopped, .failed:
            .startAndroid
        case .ready, .sleeping:
            .stopAndroid
        case .starting, .stopping, .unknown:
            .none
        }
    }
}

enum MenuBarPrimaryAction: Equatable, Sendable {
    case openAPKRun
    case startAndroid
    case stopAndroid
    case none
}
