import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeCore

/// The in-process session service used by `apkrun dev launch` before the XPC client is introduced (#27).
///
/// It composes the RuntimeCore registry with the embedded development boot. The API remains narrow: display 0, one
/// package session, and the stop policy that finishes the package's tasks.
public actor EmbeddedRuntimeService: RuntimeSessionService, PackageMutationSessionHandling {
    private let registry: SessionRegistry
    private var sessionID: SessionID?
    private var packageID: String?
    private var taskID: Int32?
    private var launchAwaitsVisibleTaskFrame = false
    private var visibleTaskFrameSequence: UInt64?
    private var frameReconciliationSessionID: SessionID?
    private var guestAgent: (any EmbeddedSessionGuestAgent)?
    private let developerDisplay: DeveloperDisplay?
    private let displayPool: DisplayPool?
    private let inputRoute: DevInputRoute?
    private let stopSignal: DevBootStopSignal?
    private let windowState: DevBootAppWindowState?
    private let onAppFramePresented: (@Sendable () async -> Void)?
    private let onTerminalSessionReconciled: (@Sendable (AppSessionSnapshot) async -> Void)?
    private var sessionOperationInFlight = false
    private var sessionOperationWaiters: [CheckedContinuation<Void, Never>] = []
    private var guestAgentResynchronizationHandlerID: UUID?

    /// Creates a service for one embedded CLI run.
    public init(registry: SessionRegistry? = nil, logSink: (any LogSink)? = nil) {
        self.registry = registry ?? SessionRegistry(logSink: logSink)
        developerDisplay = nil
        displayPool = nil
        inputRoute = nil
        stopSignal = nil
        windowState = nil
        onAppFramePresented = nil
        onTerminalSessionReconciled = nil
    }

    init(
        registry: SessionRegistry? = nil,
        logSink: (any LogSink)? = nil,
        developerDisplay: DeveloperDisplay,
        stopSignal: DevBootStopSignal,
        displayPool: DisplayPool? = nil,
        inputRoute: DevInputRoute? = nil,
        windowState: DevBootAppWindowState? = nil,
        onAppFramePresented: (@Sendable () async -> Void)? = nil,
        onTerminalSessionReconciled: (@Sendable (AppSessionSnapshot) async -> Void)? = nil
    ) {
        self.registry = registry ?? SessionRegistry(logSink: logSink)
        self.developerDisplay = developerDisplay
        self.displayPool = displayPool
        self.inputRoute = inputRoute
        self.stopSignal = stopSignal
        self.windowState = windowState
        self.onAppFramePresented = onAppFramePresented
        self.onTerminalSessionReconciled = onTerminalSessionReconciled
    }

    func attachGuestAgent(_ guestAgent: any EmbeddedSessionGuestAgent) async {
        if let previous = self.guestAgent, let handlerID = guestAgentResynchronizationHandlerID {
            await previous.removeResynchronizationHandler(handlerID)
        }
        self.guestAgent = guestAgent
        guestAgentResynchronizationHandlerID = await guestAgent.addResynchronizationHandler { [weak self] snapshot in
            await self?.reconcileGuestSnapshot(snapshot)
        }
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
            _ = await registry.stopCompleted(sessionID: sessionID)
            taskID = nil
            clearLaunchFrameReadiness()
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
        guard developerDisplay != nil, stopSignal != nil else {
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

        let report: GuestLaunchReport
        do throws(GuestAgentFailure) {
            report = try await guestAgent.launch(package: requestedPackage, displayID: snapshot.displayID)
        } catch {
            guard Self.isTransientGuestLaunchFailure(error) else {
                await markRuntimeFailed()
                throw Self.wireError(for: error)
            }
            // Keep the launch session and native window alive. The reconnect callback will
            // reconcile the snapshot, then retry or finish the first-frame transition.
            return try Self.launchResult(for: snapshot)
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

        switch await waitForVisibleTaskFrame(
            packageID: requestedPackage,
            taskID: report.taskID,
            displayID: snapshot.displayID,
            using: guestAgent
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
        let isInstalled: Bool
        do throws(GuestAgentFailure) {
            isInstalled = try await guestAgent.isInstalled(requestedPackage)
        } catch {
            throw Self.wireError(for: error)
        }
        guard isInstalled else {
            throw Self.packageNotInstalledError
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
        switch await Self.forceStopApplication(package: requestedPackage, using: guestAgent) {
        case .success(true):
            if hadSession {
                if let current {
                    _ = await registry.stopCompleted(sessionID: current.id)
                }
                taskID = nil
                clearLaunchFrameReadiness()
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

    /// Reports whether this package still owns a live app session.
    func hasActiveSession(packageID: RuntimePackageID) async -> Bool {
        await registry.session(packageID: packageID.rawValue) != nil
    }

    /// Closes this package's active window with the package-removal reason before uninstall.
    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }

        let package = request.packageID.rawValue
        guard let current = await registry.session(packageID: package) else { return }
        guard let guestAgent else {
            throw .runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent is unavailable.",
                remediation: "Boot Android with the development Guest Agent, then retry."
            )
        }
        guard current.state != .closing else {
            throw .runtime(
                "operationInProgress",
                message: "The app window is already closing.",
                remediation: "Wait for the window to close, then retry the uninstall."
            )
        }
        await inputRoute?.unbind()
        var shouldForceStop = true
        do {
            _ = try await windowClosed()
        } catch {
            guard let latest = await registry.session(current.id), latest.state.isEnded else {
                throw Self.wireError(for: error)
            }
            shouldForceStop = false
        }

        if shouldForceStop {
            switch await Self.forceStopApplication(package: package, using: guestAgent) {
            case .success(true):
                _ = await registry.stopCompleted(sessionID: current.id, endReason: .packageUninstalled)
                taskID = nil
                clearLaunchFrameReadiness()
            case .success(false):
                _ = await registry.stopFailed(packageID: package)
                throw .runtime(
                    "guestAgentOperationFailed",
                    message: "Android still reports tasks for this app.",
                    remediation: "Wait for the app to close, then try again."
                )
            case .failure(let failure):
                _ = await registry.stopFailed(packageID: package)
                throw Self.wireError(for: failure)
            }
        } else {
            _ = await registry.stopCompleted(sessionID: current.id, endReason: .packageUninstalled)
            taskID = nil
        }
    }

    /// Registers a package session and moves it into the runtime wait state.
    @discardableResult
    public func requestSession(packageID: String) async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        let snapshot = try await registry.request(packageID: packageID)
        sessionID = snapshot.id
        self.packageID = packageID
        taskID = nil
        clearLaunchFrameReadiness()
        frameReconciliationSessionID = nil
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
        let snapshot = try await transition(to: .launching)
        launchAwaitsVisibleTaskFrame = true
        visibleTaskFrameSequence = nil
        return snapshot
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
            clearLaunchFrameReadiness()
            return current
        }
        let snapshot = try await transition(to: .running)
        clearLaunchFrameReadiness()
        await onAppFramePresented?()
        return snapshot
    }

    /// Begins the close policy before the Guest Agent removes the package's tasks.
    @discardableResult
    public func windowClosed() async throws(SessionRegistryFailure) -> AppSessionSnapshot {
        clearLaunchFrameReadiness()
        return try await transition(to: .closing)
    }

    /// Applies the final task-vanished event after the Guest Agent confirms task removal.
    @discardableResult
    public func taskVanished() async -> AppSessionSnapshot? {
        guard let packageID, let taskID else {
            return nil
        }
        let snapshot = await registry.taskVanished(packageID: packageID, taskID: taskID)
        if snapshot?.state.isEnded == true {
            clearLaunchFrameReadiness()
        }
        return snapshot
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
            let snapshot = await registry.taskAppeared(packageID: eventPackage, taskID: eventTaskID)
            if let snapshot,
                snapshot.state == .launching,
                snapshot.taskIDs.contains(eventTaskID),
                taskID == eventTaskID,
                let guestAgent
            {
                let isVisible = await refreshVisibleTaskFrameSequence(
                    packageID: eventPackage,
                    taskID: eventTaskID,
                    displayID: snapshot.displayID,
                    using: guestAgent
                )
                if isVisible {
                    if let sessionID {
                        scheduleFirstFrameReconciliation(sessionID: sessionID, taskID: eventTaskID)
                    }
                }
            }
            return snapshot
        case .vanished(let eventPackage, let eventTaskID) where eventPackage == packageID:
            if let snapshot = await currentSession(),
                snapshot.taskIDs.isEmpty
                    || (snapshot.taskIDs.count == 1 && snapshot.taskIDs.contains(eventTaskID))
            {
                // A last-task event releases the display lease below. End the router registration first.
                await inputRoute?.unbind()
            }
            let snapshot = await registry.taskVanished(packageID: eventPackage, taskID: eventTaskID)
            if snapshot?.state.isEnded == true {
                clearLaunchFrameReadiness()
            }
            return snapshot
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

    /// Applies the guest's complete state before the supervisor releases requests queued during reconnect.
    private func reconcileGuestSnapshot(_ guestSnapshot: GuestSnapshotState) async {
        guard let sessionID else {
            return
        }
        let result: SessionReconciliationResult
        do throws(SessionRegistryFailure) {
            result = try await registry.reconcile(sessionID: sessionID, against: guestSnapshot)
        } catch {
            return
        }
        guard self.sessionID == sessionID else {
            return
        }

        if result.session.state.isEnded {
            clearLaunchFrameReadiness()
            frameReconciliationSessionID = nil
            let inputCleanupTask = await inputRoute?.detachForGuestReconciliation()
            scheduleTerminalSessionReconciliation(result.session, inputCleanupTask: inputCleanupTask)
        }

        if result.session.state == .launching, launchAwaitsVisibleTaskFrame {
            if let observedTaskID = visibleTaskID(in: guestSnapshot, session: result.session) {
                taskID = observedTaskID
                rememberVisibleTaskFrameSequence()
                scheduleFirstFrameReconciliation(sessionID: sessionID, taskID: observedTaskID)
            } else if let taskID,
                let observed = guestSnapshot.tasks[taskID],
                observed.package == result.session.packageID,
                observed.displayID == result.session.displayID
            {
                // A hidden task cannot retain readiness from an earlier visible period.
                visibleTaskFrameSequence = nil
            }
        }

        guard result.action == .relaunchApplication else {
            return
        }
        // GuestAgentSupervisor awaits this handler before reopening normal sends. Defer the relaunch so it can use
        // the newly ready connection, and serialize it with any launch or close already in progress.
        Task { [weak self] in
            await self?.relaunchAfterResynchronization(sessionID: sessionID)
        }
    }

    private func scheduleTerminalSessionReconciliation(
        _ session: AppSessionSnapshot,
        inputCleanupTask: Task<Void, Never>?
    ) {
        Task { [weak self, registry = self.registry] in
            await inputCleanupTask?.value
            await registry.waitForPendingDisplayReleases()
            await self?.finishTerminalSessionReconciliation(session)
        }
    }

    private func finishTerminalSessionReconciliation(_ session: AppSessionSnapshot) async {
        if let onTerminalSessionReconciled {
            await onTerminalSessionReconciled(session)
        } else {
            switch session.state {
            case .ended(.appExited):
                // A single-window dev command owns the VM and stops it when its app exits.
                await stopSignal?.signal(.appExited)
            case .ended(.error(.displayLost)):
                // Do not leave a single-window command waiting after Android loses its display.
                await stopSignal?.signal(.appWindowCloseFailed)
            default:
                break
            }
        }
    }

    /// Reissues a lost launch reply after reconnect without waiting for the app's first frame.
    private func relaunchAfterResynchronization(sessionID: SessionID) async {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }

        guard self.sessionID == sessionID,
            let current = await registry.session(sessionID),
            current.state == .launching,
            current.taskIDs.isEmpty,
            await windowState?.isClosed() != true,
            let guestAgent
        else {
            return
        }

        visibleTaskFrameSequence = nil
        taskID = nil
        let report: GuestLaunchReport
        do {
            report = try await guestAgent.launch(package: current.packageID, displayID: current.displayID)
        } catch {
            if !Self.isTransientGuestLaunchFailure(error) {
                await finishFailedResynchronization(sessionID: sessionID)
            }
            return
        }

        guard self.sessionID == sessionID,
            let latest = await registry.session(sessionID),
            latest.state == .launching
        else {
            return
        }
        if let completed = await registry.launchCompleted(packageID: latest.packageID, taskID: report.taskID) {
            taskID = report.taskID
            if completed.state.isEnded {
                clearLaunchFrameReadiness()
                await inputRoute?.unbind()
                if let onTerminalSessionReconciled {
                    await onTerminalSessionReconciled(completed)
                } else {
                    switch completed.state {
                    case .ended(.appExited):
                        await stopSignal?.signal(.appExited)
                    case .ended(.error(.displayLost)):
                        await stopSignal?.signal(.appWindowCloseFailed)
                    default:
                        break
                    }
                }
            } else if completed.state == .launching {
                scheduleFirstFrameReconciliation(sessionID: sessionID, taskID: report.taskID)
            }
        } else if let current = await registry.session(sessionID),
            current.state == .launching,
            current.taskIDs.contains(report.taskID)
        {
            // A launch already in flight may have recorded this same task while the gate was held.
            taskID = report.taskID
            scheduleFirstFrameReconciliation(sessionID: sessionID, taskID: report.taskID)
        }
    }

    private func scheduleFirstFrameReconciliation(sessionID: SessionID, taskID: Int32) {
        guard frameReconciliationSessionID != sessionID else {
            return
        }
        frameReconciliationSessionID = sessionID
        Task { [weak self] in
            await self?.completeObservedLaunchAfterResynchronization(sessionID: sessionID, taskID: taskID)
        }
    }

    /// Finishes the normal first-frame transition when a reconnect snapshot already contains the launched app.
    private func completeObservedLaunchAfterResynchronization(sessionID: SessionID, taskID: Int32) async {
        await acquireSessionOperation()
        defer { releaseSessionOperation() }
        defer {
            if frameReconciliationSessionID == sessionID {
                frameReconciliationSessionID = nil
            }
        }

        guard self.sessionID == sessionID,
            let current = await registry.session(sessionID),
            current.state == .launching,
            current.taskIDs.contains(taskID),
            let packageID,
            let guestAgent
        else {
            return
        }

        switch await waitForVisibleTaskFrame(
            packageID: packageID,
            taskID: taskID,
            displayID: current.displayID,
            using: guestAgent
        ) {
        case .presented:
            guard self.sessionID == sessionID,
                let latest = await registry.session(sessionID),
                latest.state == .launching,
                latest.taskIDs.contains(taskID)
            else {
                return
            }
            _ = try? await firstFramePresented()
        case .timedOut:
            guard self.sessionID == sessionID,
                let latest = await registry.session(sessionID),
                latest.state == .launching,
                latest.taskIDs.contains(taskID)
            else {
                return
            }
            await finishFailedResynchronization(sessionID: sessionID)
        case .stopped, .windowClosed:
            break
        }
    }

    /// Waits for a visible task and a later committed frame sequence.
    ///
    /// Guest task visibility identifies the launched app on this Android display. The frame watermark is captured
    /// only after that signal and includes accepted flushes still held by the presenter, so a boot/home frame cannot
    /// satisfy launch readiness merely because its native commit happened after `LaunchApplication` began.
    private func waitForVisibleTaskFrame(
        packageID: String,
        taskID: Int32,
        displayID: Int32,
        using guestAgent: any EmbeddedSessionGuestAgent,
        timeout: Duration = .seconds(15),
        pollInterval: Duration = .milliseconds(50)
    ) async -> DevBoot.FrameWaitResult {
        guard let developerDisplay, let stopSignal else {
            return .timedOut
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await windowState?.isClosed() == true {
                return .windowClosed
            }
            if let cause = await stopSignal.current() {
                return .stopped(cause)
            }
            await refreshVisibleTaskFrameSequence(
                packageID: packageID,
                taskID: taskID,
                displayID: displayID,
                using: guestAgent
            )
            if let visibleTaskFrameSequence,
                developerDisplay.latestWindowFrameSequence > visibleTaskFrameSequence
            {
                return .presented
            }
            try? await Task.sleep(for: pollInterval)
        }
        if await windowState?.isClosed() == true {
            return .windowClosed
        }
        if let cause = await stopSignal.current() {
            return .stopped(cause)
        }
        return .timedOut
    }

    @discardableResult
    private func refreshVisibleTaskFrameSequence(
        packageID: String,
        taskID: Int32,
        displayID: Int32,
        using guestAgent: any EmbeddedSessionGuestAgent
    ) async -> Bool {
        guard launchAwaitsVisibleTaskFrame,
            self.packageID == packageID,
            self.taskID == taskID,
            let developerDisplay
        else {
            return false
        }
        let isVisible = await guestAgent.isTaskVisible(
            packageID: packageID,
            taskID: taskID,
            displayID: displayID
        )
        guard launchAwaitsVisibleTaskFrame, self.packageID == packageID, self.taskID == taskID else {
            return false
        }
        guard isVisible else {
            visibleTaskFrameSequence = nil
            return false
        }
        if visibleTaskFrameSequence == nil {
            visibleTaskFrameSequence = developerDisplay.latestReadyFrameSequence
        }
        return true
    }

    private func rememberVisibleTaskFrameSequence() {
        guard launchAwaitsVisibleTaskFrame, visibleTaskFrameSequence == nil,
            let developerDisplay
        else {
            return
        }
        visibleTaskFrameSequence = developerDisplay.latestReadyFrameSequence
    }

    private func visibleTaskID(in snapshot: GuestSnapshotState, session: AppSessionSnapshot) -> Int32? {
        let matches = snapshot.tasks.values.filter {
            $0.visible
                && $0.package == session.packageID
                && $0.displayID == session.displayID
                && session.taskIDs.contains($0.taskID)
        }
        if let taskID, matches.contains(where: { $0.taskID == taskID }) {
            return taskID
        }
        return matches.count == 1 ? matches[0].taskID : nil
    }

    private func clearLaunchFrameReadiness() {
        launchAwaitsVisibleTaskFrame = false
        visibleTaskFrameSequence = nil
    }

    private func finishFailedResynchronization(sessionID: SessionID) async {
        await markRuntimeFailed()
        await inputRoute?.unbind()
        guard let terminal = await registry.session(sessionID),
            terminal.state == .ended(.error(.runtimeFailed))
        else {
            return
        }
        if let onTerminalSessionReconciled {
            await onTerminalSessionReconciled(terminal)
        } else {
            await stopSignal?.signal(.appWindowCloseFailed)
        }
    }

    private func markRuntimeFailed() async {
        clearLaunchFrameReadiness()
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

    private static func forceStopApplication(
        package: String,
        using guestAgent: any EmbeddedSessionGuestAgent
    ) async -> Result<Bool, GuestAgentFailure> {
        do {
            return .success(try await guestAgent.forceStopApplication(package: package))
        } catch {
            return .failure(error)
        }
    }

    private static var packageNotInstalledError: RuntimeWireError {
        return .runtime(
            "packageNotInstalled",
            message: "This app is not installed in Android.",
            remediation: "Install the app first, then try again."
        )
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
        if case .operationFailed(let reason) = failure {
            return .runtime(
                "guestAgentOperationFailed",
                message: "The Guest Agent didn't complete the request: \(reason).",
                remediation: "Try again. If it fails again, restart Android."
            )
        }
        return .runtime(
            "guestAgentOperationFailed",
            message: "The Android Guest Agent could not complete the app operation.",
            remediation: "Check the Android runtime and try again."
        )
    }

    /// Keeps a lost launch reply reconcilable; the snapshot decides whether to retain or relaunch the task.
    private static func isTransientGuestLaunchFailure(_ failure: GuestAgentFailure) -> Bool {
        switch failure {
        case .connectTimedOut:
            true
        case .stopped, .requiredAgentUnavailable:
            false
        case .operationFailed(let reason):
            reason == "disconnected"
                || reason.hasPrefix("timeout.")
                || reason.hasPrefix("agentUnavailable.")
                || reason == "handshakeTimedOut"
        case .bundleMissing, .installFailed, .startFailed, .handshakeFailed, .adb:
            false
        }
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
    func isTaskVisible(packageID: String, taskID: Int32, displayID: Int32) async -> Bool
    func stopApplication(package: String) async throws(GuestAgentFailure) -> Bool
    func forceStopApplication(package: String) async throws(GuestAgentFailure) -> Bool
    func addResynchronizationHandler(
        _ handler: @escaping @Sendable (GuestSnapshotState) async -> Void
    ) async -> UUID
    func removeResynchronizationHandler(_ id: UUID) async
}

extension EmbeddedSessionGuestAgent {
    func isTaskVisible(packageID: String, taskID: Int32, displayID: Int32) async -> Bool {
        false
    }

    func addResynchronizationHandler(
        _ handler: @escaping @Sendable (GuestSnapshotState) async -> Void
    ) async -> UUID {
        UUID()
    }

    func removeResynchronizationHandler(_ id: UUID) async {}
}

extension DevelopmentGuestAgent: EmbeddedSessionGuestAgent {
    func isInstalled(_ package: String) async throws(GuestAgentFailure) -> Bool {
        try await queryPackage(package) != nil
    }

    func isTaskVisible(packageID: String, taskID: Int32, displayID: Int32) async -> Bool {
        let snapshot = await supervisor.snapshot
        guard let task = snapshot.tasks[taskID] else {
            return false
        }
        return task.package == packageID && task.displayID == displayID && task.visible
    }

    func addResynchronizationHandler(
        _ handler: @escaping @Sendable (GuestSnapshotState) async -> Void
    ) async -> UUID {
        await supervisor.addResynchronizationHandler(handler)
    }

    func removeResynchronizationHandler(_ id: UUID) async {
        await supervisor.removeResynchronizationHandler(id)
    }
}

extension AppSessionState {
    fileprivate var isEnded: Bool {
        if case .ended = self { true } else { false }
    }
}
