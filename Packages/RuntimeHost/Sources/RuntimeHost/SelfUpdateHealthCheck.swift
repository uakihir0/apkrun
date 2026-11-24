import DiagnosticsCore
import Foundation
import RuntimeAPI

/// `maintenance.selfUpdate` (runtime-maintenance.md §12): pass when APKRun is
/// up to date and checked within a week; info when an update is available or
/// automatic checks are off; the warnings fire in spec order.
struct SelfUpdateHealthCheck: HealthCheck {
    /// Everything the check needs, gathered on the host actor.
    struct Snapshot: Sendable {
        var latest: AvailableRelease?
        var critical: Bool
        var lastCheckedAt: Date?
        var lastError: WireError?
        var criticalNotifiedAt: Date?
        var autoCheckEnabled: Bool
        var hostState: HostState
        /// Seconds the daemon has been `restartPending` or `updating`.
        var stateSince: TimeInterval?
        /// The on-disk build, when it is older than the service (§3.6).
        var hostDowngraded: Bool
        var feedConfigured: Bool
    }

    private let snapshot: @Sendable () async -> Snapshot
    private let now: @Sendable () -> Date

    let id = "maintenance.selfUpdate"
    let group = HealthGroup.maintenance
    let requirement = HealthRequirement.daemon
    let cost = HealthCost.quick
    let title = LocalizedText(key: "maintenance.selfUpdate", fallback: "APKRun updates")

    init(
        snapshot: @escaping @Sendable () async -> Snapshot,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.snapshot = snapshot
        self.now = now
    }

    func run(_ context: HealthContext) async -> HealthResult {
        let s = await snapshot()
        let current = now()
        var warnings: [String] = []

        if s.critical, let notified = s.criticalNotifiedAt,
            current.timeIntervalSince(notified) > 3 * 24 * 3600
        {
            warnings.append("criticalUpdateWaiting")
        }
        if s.autoCheckEnabled, s.feedConfigured,
            s.lastCheckedAt.map({ current.timeIntervalSince($0) > 7 * 24 * 3600 }) ?? true
        {
            warnings.append("selfUpdateCheckOverdue")
        }
        if case .restartPending = s.hostState,
            (s.stateSince ?? 0) > 24 * 3600
        {
            warnings.append("serviceVersionMismatch")
        }
        if case .updating = s.hostState,
            (s.stateSince ?? 0) > 24 * 3600
        {
            warnings.append("hostUpdateAbandoned")
        }
        if s.hostDowngraded {
            warnings.append("hostDowngraded")
        }

        let state: HealthState
        if !warnings.isEmpty {
            state = .warning
        } else if s.latest != nil || !s.autoCheckEnabled {
            state = .info
        } else {
            state = .pass
        }
        return HealthResult(
            id: id,
            group: group,
            state: state,
            title: title,
            detail: warnings.first ?? s.lastError?.code,
            error: nil,
            measuredAt: context.clock.now
        )
    }
}
