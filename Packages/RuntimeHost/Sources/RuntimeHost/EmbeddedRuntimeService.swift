import DiagnosticsCore
import Foundation
import RuntimeCore

/// The in-process session service used by `apkrun dev launch` before the XPC client is introduced (#026).
///
/// It composes the RuntimeCore registry with the embedded development boot. The API remains narrow: display 0, one
/// package session, and the stop policy that finishes the package's tasks.
public actor EmbeddedRuntimeService {
    private let registry: SessionRegistry
    private var sessionID: SessionID?
    private var packageID: String?
    private var taskID: Int32?

    /// Creates a service for one embedded CLI run.
    public init(registry: SessionRegistry? = nil, logSink: (any LogSink)? = nil) {
        self.registry = registry ?? SessionRegistry(logSink: logSink)
    }

    /// Registers a package session and moves it into the runtime wait state.
    @discardableResult
    public func requestSession(packageID: String) async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        let snapshot = try await registry.request(packageID: packageID)
        sessionID = snapshot.id
        self.packageID = packageID
        guard snapshot.state == .requested else {
            return snapshot
        }
        return try await registry.transition(snapshot.id, to: .waitingForRuntime)
    }

    /// Records that Android is ready and the embedded session is using primary display 0.
    @discardableResult
    public func displayReady() async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        try await transition(to: .acquiringDisplay)
    }

    /// Records that the Guest Agent is starting the requested package.
    @discardableResult
    public func beginLaunch() async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        try await transition(to: .launching)
    }

    /// Adds the task returned by `LaunchApplication`.
    @discardableResult
    public func launched(taskID: Int32) async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        guard let packageID, let snapshot = await registry.launchCompleted(packageID: packageID, taskID: taskID) else {
            throw .sessionNotFound
        }
        self.taskID = taskID
        return snapshot
    }

    /// Marks the first post-launch display frame as running.
    @discardableResult
    public func firstFramePresented() async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        if let current = await currentSession(), current.state.isEnded {
            return current
        }
        return try await transition(to: .running)
    }

    /// Begins the close policy before the Guest Agent removes the package's tasks.
    @discardableResult
    public func windowClosed() async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        try await transition(to: .closing)
    }

    /// Applies the final task-vanished event after the Guest Agent confirms task removal.
    @discardableResult
    public func taskVanished() async -> AppSessionSnapshot? {
        guard let packageID, let taskID else {
            return nil
        }
        return await registry.taskVanished(packageID: packageID, taskID: taskID)
    }

    /// Applies one Guest Agent task event and returns the updated session when it belongs to this package.
    @discardableResult
    public func taskEvent(_ event: DevelopmentGuestTaskEvent) async -> AppSessionSnapshot? {
        guard let packageID else {
            return nil
        }
        switch event {
        case .appeared(let eventPackage, let eventTaskID) where eventPackage == packageID:
            return await registry.taskAppeared(packageID: eventPackage, taskID: eventTaskID)
        case .vanished(let eventPackage, let eventTaskID) where eventPackage == packageID:
            return await registry.taskVanished(packageID: eventPackage, taskID: eventTaskID)
        default:
            return nil
        }
    }

    /// Ends a failed embedded session with its typed RuntimeCore category.
    @discardableResult
    public func fail(_ code: SessionFailureCode) async throws(SessionRegistryFailure) -> AppSessionSnapshot? {
        guard let sessionID, let current = await registry.session(sessionID), current.state.isEnded == false else {
            return nil
        }
        return try await registry.transition(sessionID, to: .ended(.error(code)))
    }

    /// Ends any still-live session when the embedded runtime shuts down.
    @discardableResult
    public func runtimeStopped() async throws(SessionRegistryFailure) -> AppSessionSnapshot? {
        guard let sessionID, let current = await registry.session(sessionID), current.state.isEnded == false else {
            return nil
        }
        return try await registry.transition(sessionID, to: .ended(.runtimeStopped))
    }

    /// The current embedded session, if one was requested.
    public func currentSession() async -> AppSessionSnapshot? {
        guard let sessionID else {
            return nil
        }
        return await registry.session(sessionID)
    }

    private func transition(to state: AppSessionState) async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        guard let sessionID else {
            throw .sessionNotFound
        }
        return try await registry.transition(sessionID, to: state)
    }
}

extension AppSessionState {
    fileprivate var isEnded: Bool {
        if case .ended = self { true } else { false }
    }
}
