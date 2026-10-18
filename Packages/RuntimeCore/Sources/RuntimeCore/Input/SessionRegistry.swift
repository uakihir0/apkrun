import DiagnosticsCore
import Foundation

/// A snapshot of one embedded app session on primary display 0.
public struct AppSessionSnapshot: Sendable, Equatable {
    /// The stable identity used by the input router.
    public let id: SessionID
    /// The Android package owned by this session.
    public let packageID: String
    /// The Android display used by this session. #026 supports display 0 only.
    public let displayID: Int32
    /// Current lifecycle state.
    public let state: AppSessionState
    /// Android task IDs currently associated with the package session.
    public let taskIDs: Set<Int32>

}

/// Errors returned by the embedded display-0 session registry.
public enum SessionRegistryFailure: Error, Sendable, Equatable {
    /// The request did not name a package.
    case invalidPackageIdentifier
    /// A different live app already owns primary display 0.
    case displayInUse(packageID: String)
    /// The session is no longer registered.
    case sessionNotFound
    /// The requested state change is not in the AppSessionState transition table.
    case invalidTransition(from: AppSessionState, to: AppSessionState)
}

/// Owns app-session lifecycle and package/task mapping for the embedded #026 path on display 0.
///
/// The registry is intentionally limited to one primary display. #028 introduces display leases and #030 allows
/// concurrent sessions. The same package request reuses its live session so repeated launch requests do not create
/// duplicate windows or Android tasks.
public actor SessionRegistry {
    private struct Entry {
        let id: SessionID
        let packageID: String
        var state: AppSessionState
        var taskIDs: Set<Int32>
        var launchReplyPending = false
        var vanishedDuringLaunch: Set<Int32> = []

        var snapshot: AppSessionSnapshot {
            AppSessionSnapshot(id: id, packageID: packageID, displayID: 0, state: state, taskIDs: taskIDs)
        }
    }

    private var entries: [SessionID: Entry] = [:]
    private let logSink: (any LogSink)?

    /// Creates an empty registry for embedded display-0 sessions.
    public init(logSink: (any LogSink)? = nil) {
        self.logSink = logSink
    }

    /// Requests a session, reusing the existing live session for the same package.
    public func request(packageID: String) throws(SessionRegistryFailure) -> AppSessionSnapshot {
        guard Self.isPackageIdentifier(packageID) else {
            throw .invalidPackageIdentifier
        }
        if let existing = entries.values.first(where: { $0.packageID == packageID && !$0.state.isEnded }) {
            return existing.snapshot
        }
        if let occupied = entries.values.first(where: { $0.state.isLive }) {
            throw .displayInUse(packageID: occupied.packageID)
        }
        let id = SessionID.app(UUID())
        let entry = Entry(id: id, packageID: packageID, state: .requested, taskIDs: [])
        entries[id] = entry
        log("session requested", entry: entry)
        return entry.snapshot
    }

    /// Advances a session through the documented lifecycle.
    @discardableResult
    public func transition(_ id: SessionID, to next: AppSessionState) throws(SessionRegistryFailure)
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
        if next == .launching {
            entry.launchReplyPending = true
            entry.vanishedDuringLaunch.removeAll()
        }
        entries[id] = entry
        log("session state \(String(describing: previous)) -> \(String(describing: next))", entry: entry)
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
    public func launchCompleted(packageID: String, taskID: Int32) -> AppSessionSnapshot? {
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
            entries[entry.id] = entry
            log("session state \(String(describing: previous)) -> \(String(describing: entry.state))", entry: entry)
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
    public func taskVanished(packageID: String, taskID: Int32) -> AppSessionSnapshot? {
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
                log("session state \(String(describing: previous)) -> \(String(describing: next))", entry: entry)
            }
        }
        entries[entry.id] = entry
        return entry.snapshot
    }

    /// Returns a session by ID, including its terminal snapshot.
    public func session(_ id: SessionID) -> AppSessionSnapshot? {
        entries[id]?.snapshot
    }

    /// Returns the live session for a package, if any.
    public func session(packageID: String) -> AppSessionSnapshot? {
        entries.values.first(where: { $0.packageID == packageID && !$0.state.isEnded })?.snapshot
    }

    /// Returns all session snapshots in stable UUID order for diagnostics and tests.
    public func snapshot() -> [AppSessionSnapshot] {
        entries.values
            .map(\.snapshot)
            .sorted { Self.uuid(of: $0.id).uuidString < Self.uuid(of: $1.id).uuidString }
    }

    private static func canTransition(from current: AppSessionState, to next: AppSessionState) -> Bool {
        switch (current, next) {
        case (.requested, .waitingForRuntime), (.requested, .acquiringDisplay),
            (.waitingForRuntime, .acquiringDisplay), (.acquiringDisplay, .launching),
            (.launching, .running), (.running, .backgrounded), (.backgrounded, .running),
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

    private static func uuid(of id: SessionID) -> UUID {
        switch id {
        case .app(let uuid): uuid
        }
    }

    private func log(_ event: String, entry: Entry) {
        let logger = APKLogger(
            category: RuntimeLogCategory.sessions,
            sink: logSink,
            context: LogContext(
                packageID: entry.packageID,
                displayID: "0",
                sessionID: Self.uuid(of: entry.id).uuidString
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
