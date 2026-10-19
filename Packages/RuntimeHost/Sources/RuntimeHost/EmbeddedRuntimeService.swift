import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore

/// The in-process session service used by `apkrun dev launch` before the XPC client is introduced (#026).
///
/// It composes the RuntimeCore registry with the embedded development boot. The API remains narrow: display 0, one
/// package session, and the stop policy that finishes the package's tasks.
public actor EmbeddedRuntimeService: RuntimeSessionService {
    private let registry: SessionRegistry
    private var sessionID: SessionID?
    private var packageID: String?
    private var taskID: Int32?
    private var guestAgent: (any EmbeddedSessionGuestAgent)?
    private let developerDisplay: DeveloperDisplay?
    private let displayPool: DisplayPool?
    private let inputRoute: DevInputRoute?
    private let stopSignal: DevBootStopSignal?
    private let windowState: DevBootAppWindowState?
    private var sessionOperationInFlight = false
    private var sessionOperationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a service for one embedded CLI run.
    public init(registry: SessionRegistry? = nil, logSink: (any LogSink)? = nil) {
        self.registry = registry ?? SessionRegistry(logSink: logSink)
        developerDisplay = nil
        displayPool = nil
        inputRoute = nil
        stopSignal = nil
        windowState = nil
    }

    init(
        registry: SessionRegistry? = nil,
        logSink: (any LogSink)? = nil,
        developerDisplay: DeveloperDisplay,
        stopSignal: DevBootStopSignal,
        displayPool: DisplayPool? = nil,
        inputRoute: DevInputRoute? = nil,
        windowState: DevBootAppWindowState? = nil
    ) {
        self.registry = registry ?? SessionRegistry(logSink: logSink)
        self.developerDisplay = developerDisplay
        self.displayPool = displayPool
        self.inputRoute = inputRoute
        self.stopSignal = stopSignal
        self.windowState = windowState
    }

    func attachGuestAgent(_ guestAgent: any EmbeddedSessionGuestAgent) {
        self.guestAgent = guestAgent
    }

    /// Closes this window's app without touching sessions owned by sibling windows.
    ///
    /// A window can close while `launch` is still waiting for its first frame. The operation lock
    /// makes that close wait for the launch reply, so any returned task is known before deciding
    /// whether Android needs a package stop.
    func closeForWindow() async throws(RuntimeWireError) {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }

        guard let packageID,
            let sessionID,
            let current = await registry.session(sessionID),
            !current.state.isEnded
        else {
            return
        }
        await inputRoute?.unbind()
        guard !current.taskIDs.isEmpty else {
            _ = try? await registry.transition(sessionID, to: .ended(.runtimeStopped))
            return
        }
        guard let guestAgent else {
            throw .runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent is unavailable.",
                remediation: "Restart Android before closing this app window."
            )
        }
        if current.state != .closing {
            do throws(SessionRegistryFailure) {
                _ = try await registry.transition(sessionID, to: .closing)
            } catch {
                throw Self.wireError(for: error)
            }
        }
        switch await Self.stopApplication(package: packageID, using: guestAgent) {
        case .success(true):
            _ = await registry.stopCompleted(packageID: packageID)
            taskID = nil
        case .success(false):
            _ = await registry.stopFailed(packageID: packageID)
            throw .runtime(
                "guestAgentOperationFailed",
                message: "Android still reports tasks for this app.",
                remediation: "Wait for the app to close, then close its window again."
            )
        case .failure(let failure):
            _ = await registry.stopFailed(packageID: packageID)
            throw Self.wireError(for: failure)
        }
    }

    /// Unbinds input and releases this window's lease as the shared VM is stopping.
    func closeForRuntimeStop() async {
        await inputRoute?.unbind()
        _ = try? await runtimeStopped()
    }

    /// Starts the package on primary display 0 after confirming Android reports it installed.
    public func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }

        let requestedPackage = request.packageID.rawValue
        guard await windowState?.isClosed() != true else {
            throw .runtime(
                "cancelled",
                message: "The app window closed before Android could launch the app.",
                remediation: "Open another app window and try again."
            )
        }
        guard let guestAgent else {
            throw .runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent is unavailable.",
                remediation: "Boot Android with the development Guest Agent, then retry."
            )
        }
        if let current = await currentSession(), !current.state.isEnded,
            current.packageID != requestedPackage
        {
            throw Self.wireError(for: .sessionAlreadyExists(packageID: current.packageID))
        }
        let isInstalled: Bool
        do throws(GuestAgentFailure) {
            isInstalled = try await guestAgent.isInstalled(requestedPackage)
        } catch {
            await markRuntimeFailed()
            throw Self.wireError(for: error)
        }
        guard isInstalled else {
            throw .runtime(
                "packageNotInstalled",
                message: "This app is not installed in Android.",
                remediation: "Install the app first, then launch it again."
            )
        }
        guard let developerDisplay, let stopSignal else {
            throw .runtime(
                "windowUnavailable",
                message: "APKRun couldn't open an Android app window.",
                remediation: "Start the app from APKRun or use a window-backed runtime session."
            )
        }

        var snapshot: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            if let current = await currentSession(), !current.state.isEnded {
                snapshot = current
            } else {
                snapshot = try await requestSession(packageID: requestedPackage)
            }
            if snapshot.state == .waitingForRuntime {
                snapshot = try await displayReady()
            }
            if snapshot.state == .acquiringDisplay {
                snapshot = try await beginLaunch()
            }
        } catch {
            await markRuntimeFailed()
            throw Self.wireError(for: error)
        }
        switch snapshot.state {
        case .running, .backgrounded:
            return try Self.launchResult(for: snapshot)
        case .launching:
            break
        default:
            break
        }
        guard snapshot.state == .launching else {
            await markRuntimeFailed()
            throw .runtime(
                "internal",
                message: "The app session could not enter its launch state.",
                remediation: "Try launching the app again."
            )
        }

        let frameCountBeforeLaunch = developerDisplay.windowFrameCommitCount
        let report: GuestLaunchReport
        do throws(GuestAgentFailure) {
            report = try await guestAgent.launch(package: requestedPackage, displayID: snapshot.displayID)
        } catch {
            await markRuntimeFailed()
            throw Self.wireError(for: error)
        }
        do throws(SessionRegistryFailure) {
            snapshot = try await launched(taskID: report.taskID)
        } catch {
            await markRuntimeFailed()
            throw Self.wireError(for: error)
        }
        if snapshot.state.isEnded {
            return try Self.launchResult(for: snapshot)
        }

        switch await DevBoot.waitForFrame(
            after: frameCountBeforeLaunch,
            on: developerDisplay,
            stopSignal: stopSignal,
            windowState: windowState
        ) {
        case .presented:
            do throws(SessionRegistryFailure) {
                snapshot = try await firstFramePresented()
            } catch {
                await markRuntimeFailed()
                throw Self.wireError(for: error)
            }
            return try Self.launchResult(for: snapshot)
        case .timedOut:
            await markRuntimeFailed()
            throw .runtime(
                "launchTimedOut",
                message: "Android launched the app, but its window did not display a frame.",
                remediation: "Try again. If it happens again, restart Android."
            )
        case .stopped:
            throw .runtime(
                "cancelled",
                message: "The app launch was interrupted because Android is stopping.",
                remediation: "Start Android and try again."
            )
        case .windowClosed:
            throw .runtime(
                "cancelled",
                message: "The app window closed before Android displayed its first frame.",
                remediation: "Open the app again with `apkrun dev launch`."
            )
        }
    }

    /// Stops the package's Android tasks, including when no app session is currently registered.
    public func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }

        let requestedPackage = request.packageID.rawValue
        guard let guestAgent else {
            throw .runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent is unavailable.",
                remediation: "Boot Android with the development Guest Agent, then retry."
            )
        }
        let current = await registry.session(packageID: requestedPackage)
        let hadSession = current != nil
        if let current, current.state != .closing {
            // Cancel host input and its open Android gestures before the terminal transition releases the lease.
            await inputRoute?.unbind()
            do {
                _ = try await windowClosed()
            } catch {
                if await registry.session(packageID: requestedPackage)?.state.isEnded != true {
                    throw Self.wireError(for: error)
                }
            }
        }
        switch await Self.stopApplication(package: requestedPackage, using: guestAgent) {
        case .success(true):
            if hadSession {
                _ = await registry.stopCompleted(packageID: requestedPackage)
                taskID = nil
            }
            return RuntimeTerminateResult(packageID: request.packageID, hadSession: hadSession)
        case .success(false):
            if hadSession {
                _ = await registry.stopFailed(packageID: requestedPackage)
            }
            throw .runtime(
                "guestAgentOperationFailed",
                message: "Android still reports tasks for this app.",
                remediation: "Wait for the app to close, then try again."
            )
        case .failure(let failure):
            if hadSession {
                _ = await registry.stopFailed(packageID: requestedPackage)
            }
            throw Self.wireError(for: failure)
        }
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
        if let current = await currentSession(), current.state == .acquiringDisplay {
            return current
        }
        return try await transition(to: .acquiringDisplay)
    }

    /// Acquires and attaches a display lease before input is bound or the app is launched.
    @discardableResult
    func requestLeasedSession(
        packageID: String,
        configuration: DisplayConfiguration
    ) async throws(RuntimeWireError) -> AppSessionSnapshot {
        guard let displayPool, let developerDisplay else {
            throw .runtime(
                "windowUnavailable",
                message: "APKRun couldn't connect a virtual Android display to the window.",
                remediation: "Use `apkrun dev launch --display 0` or start Android with a graphics window."
            )
        }
        let snapshot: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            snapshot = try await registry.requestLeased(
                packageID: packageID,
                configuration: configuration,
                displayPool: displayPool
            )
        } catch {
            throw Self.wireError(for: error)
        }
        sessionID = snapshot.id
        self.packageID = packageID
        guard let lease = await registry.displayLease(snapshot.id) else {
            _ = try? await registry.transition(snapshot.id, to: .ended(.error(.runtimeFailed)))
            throw .runtime("internal", message: "The display lease was not recorded for the app session.")
        }
        if lease.scanout.rawValue != 0 {
            do {
                try developerDisplay.attach(lease: lease)
            } catch {
                _ = try? await registry.transition(snapshot.id, to: .ended(.error(.runtimeFailed)))
                throw .runtime(
                    "displayAttachFailed",
                    message: "APKRun couldn't connect Android's display to the native window.",
                    remediation: "Close the window, then retry the launch."
                )
            }
        }
        await inputRoute?.setDisplayID(lease.androidDisplayID)
        return snapshot
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
            await inputRoute?.reapplyFocusIfNeeded()
            return await registry.taskAppeared(packageID: eventPackage, taskID: eventTaskID)
        case .vanished(let eventPackage, let eventTaskID) where eventPackage == packageID:
            if let snapshot = await currentSession(),
                snapshot.taskIDs.isEmpty
                    || (snapshot.taskIDs.count == 1 && snapshot.taskIDs.contains(eventTaskID))
            {
                // A last-task event releases the display lease below. End the router registration first.
                await inputRoute?.unbind()
            }
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

    private func acquireSessionOperation() async {
        if !sessionOperationInFlight {
            sessionOperationInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            sessionOperationWaiters.append(continuation)
        }
    }

    private func releaseSessionOperation() {
        if sessionOperationWaiters.isEmpty {
            sessionOperationInFlight = false
        } else {
            sessionOperationWaiters.removeFirst().resume()
        }
    }

    private func markRuntimeFailed() async {
        _ = try? await fail(.runtimeFailed)
    }

    private static func launchResult(for snapshot: AppSessionSnapshot) throws(RuntimeWireError) -> RuntimeLaunchResult {
        guard case .app(let sessionID) = snapshot.id,
            let packageID = RuntimePackageID(rawValue: snapshot.packageID)
        else {
            throw .runtime(
                "internal",
                message: "APKRun could not identify the app session.",
                remediation: "Try the operation again."
            )
        }
        let phase: RuntimeSessionPhase
        switch snapshot.state {
        case .requested:
            phase = .starting
        case .waitingForRuntime:
            phase = .booting
        case .acquiringDisplay:
            phase = .waitingForPackage
        case .launching:
            phase = .launching
        case .running, .backgrounded:
            phase = .running
        case .closing, .ended:
            phase = .ended
        }
        return RuntimeLaunchResult(sessionID: sessionID, packageID: packageID, state: phase)
    }

    private static func stopApplication(
        package: String,
        using guestAgent: any EmbeddedSessionGuestAgent
    ) async -> Result<Bool, GuestAgentFailure> {
        do {
            return .success(try await guestAgent.stopApplication(package: package))
        } catch {
            return .failure(error)
        }
    }

    private static func wireError(for failure: SessionRegistryFailure) -> RuntimeWireError {
        switch failure {
        case .invalidPackageIdentifier:
            return .runtime("invalidPackageID", message: "The Android package identifier is invalid.")
        case .displayInUse(let packageID):
            return .runtime(
                "primaryDisplayBusy",
                message: "\(packageID) is already using the compatibility window mode.",
                remediation: "Close \(packageID) or switch it to the standard secondary display mode."
            )
        case .sessionAlreadyExists(let packageID):
            return .runtime(
                "sessionAlreadyExists",
                message: "\(packageID) already has a live app session on another display.",
                remediation: "Close its current window before requesting another display."
            )
        case .displayPool(.exhausted):
            return .runtime(
                "displayPoolExhausted",
                message: "APKRun could not allocate an Android app display.",
                remediation: "Close another Android app window and retry."
            )
        case .displayPool(.attachFailed):
            return .runtime(
                "displayAttachFailed",
                message: "Android couldn't create a window for the app.",
                remediation: "Restart Android. If it happens again, create a diagnostics report."
            )
        case .displayPool(.staleLease):
            return .runtime("internal", message: "The Android display lease is no longer current.")
        case .displayPool(.primaryDisplayBusy):
            return .runtime(
                "primaryDisplayBusy",
                message: "Another app is already using the compatibility window mode.",
                remediation: "Close that app or switch it to the standard secondary display mode."
            )
        case .displayPool(.primaryDisplayUnavailable):
            return .runtime(
                "displayAttachFailed",
                message: "The compatibility display has no active graphics presenter.",
                remediation: "Start Android with the primary development window, then retry."
            )
        case .displayPool(.invalidGeometry):
            return .runtime("displayGeometryInvalid", message: "The requested app window size is invalid.")
        case .displayPool(.reconfigureFailed(let stateUncertain)):
            return .runtime(
                "displayReconfigureFailed",
                message: "Android did not confirm the requested app window size.",
                remediation: stateUncertain
                    ? "Restart Android before reusing this display."
                    : "The previous display mode was restored. Try resizing again."
            )
        case .displayPool(.guest(.unavailable)):
            return .runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent is unavailable.",
                remediation: "Boot Android with the development Guest Agent, then retry."
            )
        case .displayPool(.guest(.operationFailed)):
            return .runtime(
                "guestAgentOperationFailed",
                message: "The Android Guest Agent could not apply the display policy.",
                remediation: "Restart Android and try again."
            )
        case .displayPool(.graphics(let failure)):
            return RuntimeWireError(
                domain: "graphics",
                code: "graphics.\(failure.code)",
                message: "APKRun couldn't prepare the graphics display.",
                remediation: "Restart Android. If the problem continues, create a diagnostics report."
            )
        case .sessionNotFound:
            return .runtime("internal", message: "The app session no longer exists.")
        case .invalidTransition:
            return .runtime("internal", message: "The app session is in an invalid state.")
        }
    }

    private static func wireError(for failure: GuestAgentFailure) -> RuntimeWireError {
        .runtime(
            "guestAgentOperationFailed",
            message: "The Android Guest Agent could not complete the app operation.",
            remediation: "Check the Android runtime and try again."
        )
    }

    private func transition(to state: AppSessionState) async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        guard let sessionID else {
            throw .sessionNotFound
        }
        return try await registry.transition(sessionID, to: state)
    }
}

protocol EmbeddedSessionGuestAgent: Sendable {
    func isInstalled(_ package: String) async throws(GuestAgentFailure) -> Bool
    func launch(package: String, displayID: Int32) async throws(GuestAgentFailure) -> GuestLaunchReport
    func stopApplication(package: String) async throws(GuestAgentFailure) -> Bool
}

extension DevelopmentGuestAgent: EmbeddedSessionGuestAgent {
    func isInstalled(_ package: String) async throws(GuestAgentFailure) -> Bool {
        try await queryPackage(package) != nil
    }
}

extension AppSessionState {
    fileprivate var isEnded: Bool {
        if case .ended = self { true } else { false }
    }
}
