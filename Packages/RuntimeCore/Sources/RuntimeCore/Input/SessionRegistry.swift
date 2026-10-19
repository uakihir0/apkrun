import DiagnosticsCore
import Foundation

/// A snapshot of one app session and its Android display.
public struct AppSessionSnapshot: Sendable, Equatable {
    /// The stable identity used by the input router.
    public let id: SessionID
    /// The Android package owned by this session.
    public let packageID: String
    /// The Android display used by this session.
    public let displayID: Int32
    /// Current lifecycle state.
    public let state: AppSessionState
    /// Android task IDs currently associated with the package session.
    public let taskIDs: Set<Int32>

}

/// Errors returned by the embedded and leased-display session registry.
public enum SessionRegistryFailure: Error, Sendable, Equatable {
    /// The request did not name a package.
    case invalidPackageIdentifier
    /// A different live app already owns primary display 0.
    case displayInUse(packageID: String)
    /// The package already has a session on another display or is still acquiring one.
    case sessionAlreadyExists(packageID: String)
    /// DisplayPool could not allocate or reconfigure the requested display.
    case displayPool(DisplayPoolFailure)
    /// The session is no longer registered.
    case sessionNotFound
    /// The requested state change is not in the AppSessionState transition table.
    case invalidTransition(from: AppSessionState, to: AppSessionState)
}

/// Owns app-session lifecycle and package/task mapping for embedded and leased-display sessions.
///
/// The legacy `request(packageID:)` API remains limited to one primary display. The explicit
/// `requestLeased(packageID:configuration:displayPool:)` API acquires either a secondary display or the exclusive
/// primary compatibility lease. The same package request reuses its live session so repeated launch requests do not
/// create duplicate windows or Android tasks.
public actor SessionRegistry {
    private struct Entry {
        let id: SessionID
        let packageID: String
        var displayID: Int32
        var displayMode: AndroidWindowMode?
        var state: AppSessionState
        var taskIDs: Set<Int32>
        var displayLease: DisplayLease?
        var displayPool: DisplayPool?
        var displayAcquisitionPending = false
        var stateBeforeClosing: AppSessionState?
        var launchReplyPending = false
        var vanishedDuringLaunch: Set<Int32> = []

        var snapshot: AppSessionSnapshot {
            AppSessionSnapshot(id: id, packageID: packageID, displayID: displayID, state: state, taskIDs: taskIDs)
        }
    }

    private var entries: [SessionID: Entry] = [:]
    private let logSink: (any LogSink)?

    /// Creates an empty registry for embedded and leased-display sessions.
    public init(logSink: (any LogSink)? = nil) {
        self.logSink = logSink
    }

    /// Requests a legacy session on primary display 0, reusing the existing live primary session for the package.
    public func request(packageID: String) throws(SessionRegistryFailure) -> AppSessionSnapshot {
        guard Self.isPackageIdentifier(packageID) else {
            throw .invalidPackageIdentifier
        }
        if let existing = entries.values.first(where: { $0.packageID == packageID && !$0.state.isEnded }) {
            guard existing.displayID == 0, existing.displayLease == nil, !existing.displayAcquisitionPending else {
                throw .sessionAlreadyExists(packageID: packageID)
            }
            return existing.snapshot
        }
        if let occupied = entries.values.first(where: {
            $0.displayID == 0 && $0.displayMode == .primaryDisplayCompatibility && $0.state.isLive
        }) {
            throw .displayInUse(packageID: occupied.packageID)
        }
        let id = SessionID.app(UUID())
        let entry = Entry(
            id: id,
            packageID: packageID,
            displayID: 0,
            displayMode: .primaryDisplayCompatibility,
            state: .requested,
            taskIDs: []
        )
        entries[id] = entry
        log("session requested", entry: entry)
        return entry.snapshot
    }

    /// Requests a session backed by a DisplayPool lease.
    ///
    /// The lease is released automatically when the session enters any terminal state. Repeated requests for a
    /// package that already owns a leased display reuse that session.
    public func requestLeased(
        packageID: String,
        configuration: DisplayConfiguration,
        displayPool: DisplayPool
    ) async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        guard Self.isPackageIdentifier(packageID) else {
            throw .invalidPackageIdentifier
        }
        if let existing = entries.values.first(where: { $0.packageID == packageID && !$0.state.isEnded }) {
            guard existing.displayLease != nil, existing.displayMode == configuration.mode else {
                throw .sessionAlreadyExists(packageID: packageID)
            }
            return existing.snapshot
        }
        if case .primaryDisplayCompatibility = configuration.mode,
            let occupied = entries.values.first(where: {
                $0.packageID != packageID && $0.displayID == 0
                    && $0.displayMode == .primaryDisplayCompatibility && $0.state.isLive
            })
        {
            throw .displayInUse(packageID: occupied.packageID)
        }

        let id = SessionID.app(UUID())
        let entry = Entry(
            id: id,
            packageID: packageID,
            displayID: 0,
            displayMode: configuration.mode,
            state: .acquiringDisplay,
            taskIDs: [],
            displayAcquisitionPending: true
        )
        entries[id] = entry
        log("leased session requested", entry: entry)

        let lease: DisplayLease
        do throws(DisplayPoolFailure) {
            lease = try await displayPool.acquire(for: id, configuration: configuration)
        } catch {
            entries[id] = nil
            throw .displayPool(error)
        }

        guard var current = entries[id], !current.state.isEnded, current.state == .acquiringDisplay else {
            await displayPool.release(lease)
            throw .sessionNotFound
        }
        current.displayID = lease.androidDisplayID
        current.displayLease = lease
        current.displayPool = displayPool
        current.displayAcquisitionPending = false
        entries[id] = current
        log("leased display acquired", entry: current)
        return current.snapshot
    }

    /// Advances a session through the documented lifecycle.
    @discardableResult
    public func transition(_ id: SessionID, to next: AppSessionState) async throws(SessionRegistryFailure)
        -> AppSessionSnapshot
    {
        guard var entry = entries[id] else {
            throw .sessionNotFound
        }
        guard Self.canTransition(from: entry.state, to: next) else {
            throw .invalidTransition(from: entry.state, to: next)
        }
        let previous = entry.state
        entry.state = next
        if next == .closing {
            entry.stateBeforeClosing = previous
        } else if next.isEnded {
            entry.stateBeforeClosing = nil
        }
        if next == .launching {
            entry.launchReplyPending = true
            entry.vanishedDuringLaunch.removeAll()
        }
        let allocationToRelease = Self.takeDisplayAllocationIfEnded(from: &entry)
        entries[id] = entry
        log("session state \(String(describing: previous)) -> \(String(describing: next))", entry: entry)
        if let allocationToRelease {
            await allocationToRelease.pool.release(allocationToRelease.lease)
        }
        return entry.snapshot
    }

    /// Completes a close after the Guest Agent confirms that the package has no remaining tasks.
    @discardableResult
    public func stopCompleted(packageID: String) async -> AppSessionSnapshot? {
        guard var entry = entries.values.first(where: { $0.packageID == packageID && $0.state == .closing }) else {
            return nil
        }
        let previous = entry.state
        entry.taskIDs.removeAll()
        entry.launchReplyPending = false
        entry.vanishedDuringLaunch.removeAll()
        entry.stateBeforeClosing = nil
        entry.state = .ended(.userClosed)
        let allocationToRelease = Self.takeDisplayAllocationIfEnded(from: &entry)
        entries[entry.id] = entry
        log("session state \(String(describing: previous)) -> \(String(describing: entry.state))", entry: entry)
        if let allocationToRelease {
            await allocationToRelease.pool.release(allocationToRelease.lease)
        }
        return entry.snapshot
    }

    /// Restores the previous live state when the Guest Agent could not finish a close.
    @discardableResult
    public func stopFailed(packageID: String) -> AppSessionSnapshot? {
        guard var entry = entries.values.first(where: { $0.packageID == packageID && $0.state == .closing }),
            let previous = entry.stateBeforeClosing
        else {
            return nil
        }
        entry.state = previous
        entry.stateBeforeClosing = nil
        entries[entry.id] = entry
        log("session close failed; restored \(String(describing: previous))", entry: entry)
        return entry.snapshot
    }

    /// Associates a task reported by the Guest Agent with the package session.
    @discardableResult
    public func taskAppeared(packageID: String, taskID: Int32) -> AppSessionSnapshot? {
        guard taskID >= 0,
            var entry = entries.values.first(where: { $0.packageID == packageID && $0.state.isLive })
        else {
            return nil
        }
        entry.vanishedDuringLaunch.remove(taskID)
        let inserted = entry.taskIDs.insert(taskID).inserted
        entries[entry.id] = entry
        if inserted {
            log("task appeared id=\(taskID)", entry: entry)
        }
        return entry.snapshot
    }

    /// Reconciles the task ID returned by `LaunchApplication` with events received while the call was in flight.
    @discardableResult
    public func launchCompleted(packageID: String, taskID: Int32) async -> AppSessionSnapshot? {
        guard taskID >= 0,
            var entry = entries.values.first(where: { $0.packageID == packageID && $0.state.isLive }),
            entry.state == .launching,
            entry.launchReplyPending
        else {
            return nil
        }

        entry.launchReplyPending = false
        let taskAlreadyVanished = entry.vanishedDuringLaunch.contains(taskID)
        entry.vanishedDuringLaunch.removeAll()
        if taskAlreadyVanished, !entry.taskIDs.contains(taskID), entry.taskIDs.isEmpty {
            let previous = entry.state
            entry.state = .ended(.appExited)
            let allocationToRelease = Self.takeDisplayAllocationIfEnded(from: &entry)
            entries[entry.id] = entry
            log("session state \(String(describing: previous)) -> \(String(describing: entry.state))", entry: entry)
            if let allocationToRelease {
                await allocationToRelease.pool.release(allocationToRelease.lease)
            }
            return entry.snapshot
        }

        let inserted = entry.taskIDs.insert(taskID).inserted
        entries[entry.id] = entry
        if inserted {
            log("task appeared id=\(taskID)", entry: entry)
        }
        return entry.snapshot
    }

    /// Removes a vanished task from its package session, retaining launch-period IDs for reply reconciliation.
    @discardableResult
    public func taskVanished(packageID: String, taskID: Int32) async -> AppSessionSnapshot? {
        guard taskID >= 0,
            var entry = entries.values.first(where: { $0.packageID == packageID && $0.state.isLive })
        else {
            return nil
        }
        let removed = entry.taskIDs.remove(taskID) != nil
        guard removed || entry.launchReplyPending else {
            return nil
        }
        log("task vanished id=\(taskID)", entry: entry)
        if entry.launchReplyPending {
            entry.vanishedDuringLaunch.insert(taskID)
            entries[entry.id] = entry
            return entry.snapshot
        }
        if entry.taskIDs.isEmpty {
            let endReason: SessionEndReason?
            switch entry.state {
            case .closing:
                endReason = .userClosed
            case .launching, .running, .backgrounded:
                endReason = .appExited
            case .requested, .waitingForRuntime, .acquiringDisplay, .ended:
                endReason = nil
            }
            if let endReason {
                let next = AppSessionState.ended(endReason)
                guard Self.canTransition(from: entry.state, to: next) else {
                    return nil
                }
                let previous = entry.state
                entry.state = next
                entry.stateBeforeClosing = nil
                log("session state \(String(describing: previous)) -> \(String(describing: next))", entry: entry)
            }
        }
        let allocationToRelease = Self.takeDisplayAllocationIfEnded(from: &entry)
        entries[entry.id] = entry
        if let allocationToRelease {
            await allocationToRelease.pool.release(allocationToRelease.lease)
        }
        return entry.snapshot
    }

    /// Returns a session by ID, including its terminal snapshot.
    public func session(_ id: SessionID) -> AppSessionSnapshot? {
        entries[id]?.snapshot
    }

    /// Returns the current display lease for one session, if it owns one.
    public func displayLease(_ id: SessionID) -> DisplayLease? {
        entries[id]?.displayLease
    }

    /// Returns the live session for a package, if any.
    public func session(packageID: String) -> AppSessionSnapshot? {
        entries.values.first(where: { $0.packageID == packageID && !$0.state.isEnded })?.snapshot
    }

    /// Returns all session snapshots in stable UUID order for diagnostics and tests.
    public func snapshot() -> [AppSessionSnapshot] {
        entries.values
            .map(\.snapshot)
            .sorted { Self.identifier(of: $0.id) < Self.identifier(of: $1.id) }
    }

    private static func takeDisplayAllocationIfEnded(
        from entry: inout Entry
    ) -> (pool: DisplayPool, lease: DisplayLease)? {
        guard entry.state.isEnded else {
            return nil
        }
        entry.displayAcquisitionPending = false
        guard let displayPool = entry.displayPool, let displayLease = entry.displayLease else { return nil }
        entry.displayPool = nil
        entry.displayLease = nil
        return (displayPool, displayLease)
    }

    private static func canTransition(from current: AppSessionState, to next: AppSessionState) -> Bool {
        switch (current, next) {
        case (.requested, .waitingForRuntime), (.requested, .acquiringDisplay),
            (.waitingForRuntime, .acquiringDisplay), (.acquiringDisplay, .launching),
            (.launching, .running), (.running, .backgrounded), (.backgrounded, .running),
            (.requested, .closing), (.waitingForRuntime, .closing), (.acquiringDisplay, .closing),
            (.launching, .closing), (.running, .closing), (.backgrounded, .closing):
            true
        case (.launching, .ended(.appExited)), (.running, .ended(.appExited)), (.backgrounded, .ended(.appExited)),
            (.running, .ended(.appCrashed)), (.backgrounded, .ended(.appCrashed)),
            (.closing, .ended(.userClosed)):
            true
        case (.ended, _):
            false
        case (_, .ended(.runtimeStopped)), (_, .ended(.runtimeUpdating)), (_, .ended(.packageUninstalled)),
            (_, .ended(.updating)), (_, .ended(.error)):
            true
        default:
            false
        }
    }

    private static func isPackageIdentifier(_ packageID: String) -> Bool {
        guard packageID.utf8.count <= 255 else {
            return false
        }
        let parts = packageID.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2
            && parts.allSatisfy { part in
                guard let first = part.first, first.isASCII, first.isLetter else {
                    return false
                }
                return part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            }
    }

    private static func identifier(of id: SessionID) -> String {
        switch id {
        case .app(let uuid): uuid.uuidString
        case .system(let use): "system:\(String(describing: use))"
        }
    }

    private func log(_ event: String, entry: Entry) {
        let logger = APKLogger(
            category: RuntimeLogCategory.sessions,
            sink: logSink,
            context: LogContext(
                packageID: entry.packageID,
                displayID: String(entry.displayID),
                sessionID: Self.identifier(of: entry.id)
            )
        )
        logger.info("\(event, .public) state=\(String(describing: entry.state), .public)")
    }
}

extension AppSessionState {
    fileprivate var isEnded: Bool {
        if case .ended = self { true } else { false }
    }

    fileprivate var isLive: Bool {
        !isEnded
    }
}
