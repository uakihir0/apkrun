import CoreGraphics
import DiagnosticsCore
import Foundation
import GuestProtocol
import RuntimeAPI
import RuntimeCore
import UpdateCore

/// Launches CLI-owned sessions on secondary displays before the daemon has a window client (#33).
///
/// This service owns no window. It drains each lease's frame stream and acknowledges frames as discarded, then marks
/// the session running as soon as Android confirms the launch operation.
public actor DaemonHeadlessSessionService: RuntimeSessionService, PackageMutationSessionHandling {
    private let guestAgent: any DaemonHeadlessGuestAgent
    private let displayPool: DisplayPool
    private let registry: SessionRegistry
    private let displayConfiguration: DisplayConfiguration
    private let onSessionEnded: @Sendable (String) async -> Void
    private var sessionsByPackage: [String: SessionID] = [:]
    /// Whether any session is still live; the §3.5 idle stop asks this.
    var hasLiveSessions: Bool { !sessionsByPackage.isEmpty }
    private var frameDrainers: [SessionID: Task<Void, Never>] = [:]
    private var readyFrameSequenceWatermarksForTesting: [UUID: UInt64] = [:]
    private var sessionsWithReadyFrameForTesting: Set<UUID> = []
    private var launchComponentsForTesting: [UUID: String] = [:]
    private var taskEventMonitor: Task<Void, Never>?
    private var guestResynchronizationHandlerID: UUID?
    private var reconciliationTasks: [UUID: Task<Void, Never>] = [:]
    private var operationInFlight = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var resynchronizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeResynchronizations = 0
    private var isShuttingDown = false
    private var didCompleteShutdown = false
    /// Called once when a session's first frame lands on its scanout (`FIRST_FRAME_DISPLAYED`).
    var firstFrameObserver: (@Sendable (SessionID) -> Void)?
    /// §7.2 (update-system.md, runtime-daemon.md §7.1): before a session is
    /// requested for a package with a pending update transaction this waits
    /// or cancels it — a pre-commit install returns to `staged`, a
    /// committing one is awaited up to 30 s.
    var packageTransactionWaiter: (@Sendable (RuntimePackageID) async -> Void)?
    /// Packages whose next session's first frame is the update's H4 (§7.2).
    private var postUpdateLaunchPackages = Set<String>()
    /// Fires when a session's first frame counts as an update's H4 (§7.2):
    /// the session waited on a committing install, then launched the new
    /// version.
    var postUpdateFirstFrameObserver: (@Sendable (RuntimePackageID) async -> Void)?

    /// Installs the §7.2 hooks once (the gate and the service are each
    /// created lazily; whichever comes second calls this).
    func setUpdateHooks(
        transactionWaiter: @escaping @Sendable (RuntimePackageID) async -> Void,
        firstFrameObserver: @escaping @Sendable (RuntimePackageID) async -> Void
    ) {
        packageTransactionWaiter = transactionWaiter
        postUpdateFirstFrameObserver = firstFrameObserver
    }
    /// Called when a session is forgotten; the reason feeds the launch record's outcome.
    var sessionEndedObserver: (@Sendable (SessionID, String) -> Void)?
    private var firstFrameMarked: Set<SessionID> = []
    /// Per-session `(sampleTime, framesPresented)` samples for the 10 s fps window.
    private var frameRateSamples: [SessionID: [(time: ContinuousClock.Instant, frames: UInt64)]] =
        [:]

    /// Creates the daemon's Guest Agent-backed headless session service.
    public init(
        guestAgent: DevelopmentGuestAgent,
        displayPool: DisplayPool,
        logSink: (any LogSink)? = nil,
        onSessionEnded: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.guestAgent = guestAgent
        self.displayPool = displayPool
        registry = SessionRegistry(logSink: logSink)
        displayConfiguration = Self.defaultDisplayConfiguration
        self.onSessionEnded = onSessionEnded
    }

    init(
        guestAgent: any DaemonHeadlessGuestAgent,
        displayPool: DisplayPool,
        registry: SessionRegistry,
        displayConfiguration: DisplayConfiguration,
        onSessionEnded: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.guestAgent = guestAgent
        self.displayPool = displayPool
        self.registry = registry
        self.displayConfiguration = displayConfiguration
        self.onSessionEnded = onSessionEnded
    }

    /// Stops background observers before Android is shut down by the daemon.
    func shutdown() async {
        if didCompleteShutdown {
            return
        }
        if isShuttingDown {
            await withCheckedContinuation { continuation in
                shutdownCallWaiters.append(continuation)
            }
            return
        }
        isShuttingDown = true
        if let handlerID = guestResynchronizationHandlerID {
            guestResynchronizationHandlerID = nil
            await guestAgent.removeResynchronizationHandler(handlerID)
        }
        if let taskEventMonitor {
            self.taskEventMonitor = nil
            taskEventMonitor.cancel()
            await taskEventMonitor.value
        }
        await waitForOperationsToFinish()
        await waitForResynchronizationsToFinish()
        let tasks = Array(reconciliationTasks.values)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }
        let drainers = Array(frameDrainers.values)
        frameDrainers.removeAll()
        for drainer in drainers {
            drainer.cancel()
        }
        for drainer in drainers {
            await drainer.value
        }
        for packageID in sessionsByPackage.keys {
            await onSessionEnded(packageID)
        }
        sessionsByPackage.removeAll()
        didCompleteShutdown = true
        let waiters = shutdownCallWaiters
        shutdownCallWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Starts a package on a leased secondary display and returns after Android confirms the launch.
    public func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        await ensureGuestObservation()
        guard !isShuttingDown else {
            throw Self.shuttingDownError
        }

        let packageID = request.packageID.rawValue
        if let existing = await registry.session(packageID: packageID) {
            sessionsByPackage[packageID] = existing.id
            noteActivity(packageID, .started)
            return try await launchExisting(existing)
        }

        let isInstalled: Bool
        do throws(GuestAgentFailure) {
            isInstalled = try await guestAgent.isInstalled(packageID)
        } catch {
            throw Self.wireError(for: error)
        }
        guard isInstalled else {
            throw .runtime(
                "packageNotInstalled",
                message: "This app is not installed in Android.",
                remediation: "Install the app first, then launch it again."
            )
        }

        // §7.2 race (update-system.md, runtime-daemon.md §7.1): a pending
        // update transaction for this package is cancelled (pre-commit) or
        // awaited up to 30 s (committing) before the session requests its
        // display.
        if let packageTransactionWaiter {
            await packageTransactionWaiter(request.packageID)
        }

        let session: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            session = try await registry.requestLeased(
                packageID: packageID,
                configuration: displayConfiguration,
                displayPool: displayPool
            )
        } catch {
            throw Self.wireError(for: error)
        }
        sessionsByPackage[packageID] = session.id
        noteActivity(packageID, .started)
        guard session.state == .acquiringDisplay,
            let lease = await registry.displayLease(session.id)
        else {
            return try await launchExisting(session)
        }
        startDrainingFrames(from: lease)

        let launching: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            launching = try await registry.transition(session.id, to: .launching)
        } catch {
            await endFailedLaunch(session.id)
            throw Self.wireError(for: error)
        }

        let report: GuestLaunchReport
        do throws(GuestAgentFailure) {
            report = try await guestAgent.launch(package: packageID, displayID: launching.displayID)
        } catch {
            if !Self.isTransientLaunchFailure(error) {
                await endFailedLaunch(session.id)
            }
            throw Self.wireError(for: error)
        }
        if case .app(let sessionID) = session.id {
            launchComponentsForTesting[sessionID] = report.component
            // The Guest Agent has resolved the launched task and its top component. Exclude every
            // frame sequence already issued for this lease, including frames still waiting on a GPU fence.
            readyFrameSequenceWatermarksForTesting[sessionID] = lease.pool.latestIssuedFrameSequence
        }

        guard let completed = await registry.launchCompleted(packageID: packageID, taskID: report.taskID) else {
            if let current = await registry.session(session.id), Self.isEnded(current.state) {
                await stopDrainingFrames(for: session.id)
                return try Self.launchResult(for: current)
            }
            if let current = await registry.session(session.id),
                current.state == .running || current.state == .backgrounded
            {
                return try Self.launchResult(for: current)
            }
            await endFailedLaunch(session.id)
            throw .runtime("internal", message: "The app launch result could not be associated with its session.")
        }
        guard !Self.isEnded(completed.state) else {
            await stopDrainingFrames(for: session.id)
            return try Self.launchResult(for: completed)
        }

        let running: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            running = try await registry.transition(session.id, to: .running)
        } catch {
            if let current = await registry.session(session.id), Self.isEnded(current.state) {
                await stopDrainingFrames(for: session.id)
                return try Self.launchResult(for: current)
            }
            await endFailedLaunch(session.id)
            throw Self.wireError(for: error)
        }
        return try Self.launchResult(for: running)
    }

    /// Stops package tasks and completes the session, releasing its secondary-display lease.
    public func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        await ensureGuestObservation()
        guard !isShuttingDown else {
            throw Self.shuttingDownError
        }

        let packageID = request.packageID.rawValue
        guard let current = await registry.session(packageID: packageID) else {
            do {
                // Release the hold only after Android confirms the stop: on
                // a failure a retained task keeps running and stays
                // protected.
                let result = try await Self.terminateWithoutSession(request, using: guestAgent)
                endAllBackgroundTasks(packageID)
                return result
            } catch Self.packageNotInstalledError {
                // Nothing can still run for a package that is not installed.
                endAllBackgroundTasks(packageID)
                throw Self.packageNotInstalledError
            }
        }
        let isInstalled: Bool
        do throws(GuestAgentFailure) {
            isInstalled = try await guestAgent.isInstalled(packageID)
        } catch {
            throw Self.wireError(for: error)
        }
        guard isInstalled else {
            throw Self.packageNotInstalledError
        }
        var shouldForceStop = true
        if current.state != .closing {
            do throws(SessionRegistryFailure) {
                _ = try await registry.transition(current.id, to: .closing)
            } catch {
                guard let latest = await registry.session(current.id), Self.isEnded(latest.state) else {
                    throw Self.wireError(for: error)
                }
                shouldForceStop = false
            }
        }

        if shouldForceStop {
            let stopped: Bool
            do throws(GuestAgentFailure) {
                stopped = try await guestAgent.forceStopApplication(package: packageID)
            } catch {
                _ = await registry.stopFailed(packageID: packageID)
                throw Self.wireError(for: error)
            }
            guard stopped else {
                _ = await registry.stopFailed(packageID: packageID)
                throw Self.guestTasksStillRunningError
            }
        }

        await stopDrainingFrames(for: current.id)
        _ = await registry.stopCompleted(sessionID: current.id)
        await forgetSession(packageID: packageID, sessionID: current.id)
        endAllBackgroundTasks(packageID)
        return RuntimeTerminateResult(packageID: request.packageID, hadSession: true)
    }

    /// Closes the package's session with `policy` (display-and-windowing.md
    /// §7.6). `stop` finishes the session's tasks through the Guest Agent;
    /// `keepRunning` moves the root task to display 0 and marks it as a
    /// background task so the runtime stays active until it ends.
    func closeSession(
        _ request: RuntimeCloseSessionRequest, policy: WireClosePolicy
    ) async throws(RuntimeWireError) -> RuntimeCloseSessionResult {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        await ensureGuestObservation()
        guard !isShuttingDown else {
            throw Self.shuttingDownError
        }

        let packageID = request.packageID.rawValue
        guard let current = await registry.session(packageID: packageID) else {
            return RuntimeCloseSessionResult(packageID: request.packageID, hadSession: false)
        }
        if current.state != .closing {
            do throws(SessionRegistryFailure) {
                _ = try await registry.transition(current.id, to: .closing)
            } catch {
                guard let latest = await registry.session(current.id), Self.isEnded(latest.state)
                else {
                    throw Self.wireError(for: error)
                }
            }
        }
        guard let latest = await registry.session(current.id), !Self.isEnded(latest.state) else {
            return RuntimeCloseSessionResult(packageID: request.packageID, hadSession: false)
        }

        switch policy {
        case .stop:
            do throws(GuestAgentFailure) {
                try await guestAgent.applyClearPolicy(latest.displayID, policy: .finishTasks)
            } catch {
                throw Self.wireError(for: error)
            }
        case .keepRunning:
            guard latest.displayID != 0 else {
                throw Self.wireError(for: GuestAgentFailure.operationFailed(
                    reason: "taskAlreadyOnDefaultDisplay"))
            }
            do throws(GuestAgentFailure) {
                try await guestAgent.applyClearPolicy(latest.displayID, policy: .moveToDefaultDisplay)
            } catch {
                throw Self.wireError(for: error)
            }
            retainBackgroundTasks(packageID, taskIDs: latest.taskIDs)
        }

        await stopDrainingFrames(for: current.id)
        _ = await registry.stopCompleted(sessionID: current.id)
        await forgetSession(packageID: packageID, sessionID: current.id)
        return RuntimeCloseSessionResult(packageID: request.packageID, hadSession: true)
    }

    /// update-system.md §8.2: launches the package and watches for its
    /// first frame or a process death within `timeouts`. The health-check
    /// session then ends without force-stopping the app — the display
    /// lease releases and Android keeps or reclaims the process on its own.
    func healthCheckLaunch(
        packageID: RuntimePackageID,
        timeouts: UpdateHealthCheckTimeouts
    ) async -> HealthLaunchResult {
        do {
            _ = try await launch(RuntimeLaunchRequest(packageID: packageID))
        } catch {
            return .launchFailed(detail: "\(error.code)")
        }
        let aliveDeadline = ContinuousClock.now + timeouts.processAlive
        let frameDeadline = aliveDeadline + timeouts.firstFrame
        var frameSeen = false
        while ContinuousClock.now < frameDeadline {
            if let sessionID = sessionsByPackage[packageID.rawValue],
                firstFrameMarked.contains(sessionID)
            {
                frameSeen = true
            }
            // §8.1: H3 watches the process for the whole survival window,
            // even after a first frame — a crash inside it is a failure.
            if frameSeen, ContinuousClock.now >= aliveDeadline { break }
            guard let current = await registry.session(packageID: packageID.rawValue),
                !Self.isEnded(current.state)
            else {
                if ContinuousClock.now < aliveDeadline {
                    return .processDied(detail: "session ended")
                }
                // The survival window already passed; no frame means H4
                // fails, not H3.
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        // §8.2: the health session ends; the app process is not stopped.
        if let current = await registry.session(packageID: packageID.rawValue) {
            _ = try? await registry.transition(current.id, to: .closing)
            await stopDrainingFrames(for: current.id)
            _ = await registry.stopCompleted(
                sessionID: current.id, endReason: .updateHealthCheck)
            await forgetSession(packageID: packageID.rawValue, sessionID: current.id)
        }
        return frameSeen ? .frameDrawn : .processAlive
    }

    /// Whether the package's session has already drawn a frame
    /// (update-system.md §8.1: a drawn frame downgrades the level to
    /// `processOnly`).
    func hasDrawnFrame(packageID: RuntimePackageID) async -> Bool {
        guard let sessionID = sessionsByPackage[packageID.rawValue] else { return false }
        return firstFrameMarked.contains(sessionID)
    }

    /// Reports whether this package still owns a live app session.
    func hasActiveSession(packageID: RuntimePackageID) async -> Bool {
        await registry.session(packageID: packageID.rawValue) != nil
    }

    /// Reports whether any app session currently has a visible window.
    func hasVisibleSession() async -> Bool {
        await registry.snapshot().contains { $0.state == .running }
    }

    /// Closes an active session with the package-removal reason before the store uninstalls Android's package.
    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError) {
        guard await acquireOperation() else {
            throw Self.shuttingDownError
        }
        defer { releaseOperation() }
        await ensureGuestObservation()
        guard !isShuttingDown else {
            throw Self.shuttingDownError
        }

        let packageID = request.packageID.rawValue
        // The hold of a keepRunning-retained task ends when the uninstall's
        // task removal surfaces as a vanish event, not before the stop is
        // confirmed; a failure here leaves the task protected.
        guard let current = await registry.session(packageID: packageID) else { return }
        var shouldForceStop = true
        if current.state != .closing {
            do throws(SessionRegistryFailure) {
                _ = try await registry.transition(current.id, to: .closing)
            } catch {
                guard let latest = await registry.session(current.id), Self.isEnded(latest.state) else {
                    throw Self.wireError(for: error)
                }
                shouldForceStop = false
            }
        }

        if shouldForceStop {
            let stopped: Bool
            do throws(GuestAgentFailure) {
                stopped = try await guestAgent.forceStopApplication(package: packageID)
            } catch {
                _ = await registry.stopFailed(packageID: packageID)
                throw Self.wireError(for: error)
            }
            guard stopped else {
                _ = await registry.stopFailed(packageID: packageID)
                throw Self.guestTasksStillRunningError
            }
        }

        await stopDrainingFrames(for: current.id)
        _ = await registry.stopCompleted(sessionID: current.id, endReason: .packageUninstalled)
        await forgetSession(packageID: packageID, sessionID: current.id)
        endAllBackgroundTasks(packageID)
    }

    static func terminateWithoutSession(
        _ request: RuntimeTerminateRequest,
        using guestAgent: any DaemonHeadlessGuestAgent
    ) async throws(RuntimeWireError) -> RuntimeTerminateResult {
        let isInstalled: Bool
        do throws(GuestAgentFailure) {
            isInstalled = try await guestAgent.isInstalled(request.packageID.rawValue)
        } catch {
            throw Self.wireError(for: error)
        }
        guard isInstalled else {
            throw Self.packageNotInstalledError
        }
        let stopped: Bool
        do throws(GuestAgentFailure) {
            stopped = try await guestAgent.forceStopApplication(package: request.packageID.rawValue)
        } catch {
            throw Self.wireError(for: error)
        }
        guard stopped else {
            throw Self.guestTasksStillRunningError
        }
        return RuntimeTerminateResult(packageID: request.packageID, hadSession: false)
    }

    private func launchExisting(_ session: AppSessionSnapshot) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        switch session.state {
        case .running, .backgrounded:
            if let lease = await registry.displayLease(session.id) {
                startDrainingFrames(from: lease)
            }
            return try Self.launchResult(for: session)
        case .launching:
            if let lease = await registry.displayLease(session.id) {
                startDrainingFrames(from: lease)
            }
            if let taskID = session.taskIDs.sorted().first {
                let completed = await registry.launchCompleted(packageID: session.packageID, taskID: taskID)
                let latest: AppSessionSnapshot
                if let completed {
                    latest = completed
                } else if let current = await registry.session(session.id) {
                    latest = current
                } else {
                    latest = session
                }
                if Self.isEnded(latest.state) {
                    await stopDrainingFrames(for: session.id)
                    return try Self.launchResult(for: latest)
                }
                let running: AppSessionSnapshot
                do throws(SessionRegistryFailure) {
                    running = try await registry.transition(session.id, to: .running)
                } catch {
                    throw Self.wireError(for: error)
                }
                return try Self.launchResult(for: running)
            }
            return try await launchExistingPendingSession(session)
        case .requested, .waitingForRuntime, .acquiringDisplay, .closing, .ended:
            throw Self.wireError(for: .sessionAlreadyExists(packageID: session.packageID))
        }
    }

    private func launchExistingPendingSession(
        _ session: AppSessionSnapshot
    ) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        let report: GuestLaunchReport
        do throws(GuestAgentFailure) {
            report = try await guestAgent.launch(package: session.packageID, displayID: session.displayID)
        } catch {
            if !Self.isTransientLaunchFailure(error) {
                await endFailedLaunch(session.id)
            }
            throw Self.wireError(for: error)
        }

        guard let completed = await registry.launchCompleted(packageID: session.packageID, taskID: report.taskID) else {
            if let current = await registry.session(session.id), Self.isEnded(current.state) {
                await stopDrainingFrames(for: session.id)
                return try Self.launchResult(for: current)
            }
            if let current = await registry.session(session.id),
                current.state == .running || current.state == .backgrounded
            {
                return try Self.launchResult(for: current)
            }
            throw .runtime("internal", message: "The app launch result could not be associated with its session.")
        }
        guard !Self.isEnded(completed.state) else {
            await stopDrainingFrames(for: session.id)
            return try Self.launchResult(for: completed)
        }

        let running: AppSessionSnapshot
        do throws(SessionRegistryFailure) {
            running = try await registry.transition(session.id, to: .running)
        } catch {
            if let current = await registry.session(session.id), Self.isEnded(current.state) {
                await stopDrainingFrames(for: session.id)
                return try Self.launchResult(for: current)
            }
            throw Self.wireError(for: error)
        }
        return try Self.launchResult(for: running)
    }

    private func ensureGuestObservation() async {
        guard !isShuttingDown else {
            return
        }
        if taskEventMonitor == nil {
            let events = await guestAgent.taskEventStream()
            guard !isShuttingDown, taskEventMonitor == nil else {
                return
            }
            let monitor = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.receiveTaskEvent(event)
                }
            }
            taskEventMonitor = monitor
        }
        guard !isShuttingDown, guestResynchronizationHandlerID == nil else {
            return
        }
        let handlerID = await guestAgent.addResynchronizationHandler { [weak self] snapshot in
            await self?.reconcileGuestSnapshot(snapshot)
        }
        if isShuttingDown || guestResynchronizationHandlerID != nil {
            await guestAgent.removeResynchronizationHandler(handlerID)
        } else {
            guestResynchronizationHandlerID = handlerID
        }
    }

    private func receiveTaskEvent(_ event: DevelopmentGuestTaskEvent) async {
        guard !isShuttingDown else {
            return
        }
        let packageID: String
        switch event {
        case .appeared(let package, _), .vanished(let package, _):
            packageID = package
        }
        if case .appeared(let package, let taskID) = event, backgroundTasks[package] != nil {
            // A retained package spawning a new task keeps that task too
            // (§7.6); a relaunching session ends the hold below.
            backgroundTasks[package]?.insert(taskID)
        }
        if case .vanished(let package, let taskID) = event {
            // A task a keepRunning close retained vanishes after its session
            // is already gone; its hold ends when the last retained task of
            // the package ends (§7.6).
            endBackgroundTask(package, taskID: taskID)
        }
        guard let current = await registry.session(packageID: packageID), !isShuttingDown else {
            return
        }

        switch event {
        case .appeared(let package, let taskID):
            guard await registry.taskAppeared(packageID: package, taskID: taskID)?.state == .launching,
                !isShuttingDown
            else {
                return
            }
            let completed = await registry.launchCompleted(packageID: package, taskID: taskID)
            let latest: AppSessionSnapshot
            if let completed {
                latest = completed
            } else if let current = await registry.session(current.id) {
                latest = current
            } else {
                return
            }
            guard latest.state == .launching, !isShuttingDown else {
                return
            }
            do throws(SessionRegistryFailure) {
                _ = try await registry.transition(latest.id, to: .running)
            } catch {
                return
            }
            // Relaunch of a package whose task a keepRunning close retained:
            // the session's own hold takes over the task's (§7.6).
            endAllBackgroundTasks(package)
        case .vanished(let package, let taskID):
            let updated = await registry.taskVanished(packageID: package, taskID: taskID)
            if let updated, Self.isEnded(updated.state) {
                await stopDrainingFrames(for: updated.id)
                await forgetSession(packageID: package, sessionID: updated.id)
            }
        }
    }

    private func reconcileGuestSnapshot(_ guestSnapshot: GuestSnapshotState) async {
        guard !isShuttingDown else {
            return
        }
        activeResynchronizations += 1
        defer { scheduleResynchronizationCompletion() }
        for sessionID in Array(sessionsByPackage.values) {
            guard !isShuttingDown, await registry.session(sessionID) != nil else {
                continue
            }
            let result: SessionReconciliationResult
            do throws(SessionRegistryFailure) {
                result = try await registry.reconcile(sessionID: sessionID, against: guestSnapshot)
            } catch {
                continue
            }
            if Self.isEnded(result.session.state) {
                await stopDrainingFrames(for: result.session.id)
                await forgetSession(packageID: result.session.packageID, sessionID: sessionID)
                continue
            }
            guard !isShuttingDown else {
                return
            }
            if result.session.state == .launching,
                let taskID = result.session.taskIDs.sorted().first
            {
                scheduleObservedLaunch(sessionID: sessionID, taskID: taskID)
            }
            if result.action == .relaunchApplication {
                scheduleRelaunch(sessionID: sessionID)
            }
        }
    }

    private func scheduleResynchronizationCompletion() {
        let taskKey = UUID()
        let task = Task { [weak self, registry = self.registry] in
            await registry.waitForPendingDisplayReleases()
            await self?.finishResynchronization()
            await self?.removeReconciliationTask(taskKey)
        }
        reconciliationTasks[taskKey] = task
    }

    private func scheduleObservedLaunch(sessionID: SessionID, taskID: Int32) {
        let taskKey = UUID()
        let task = Task { [weak self] in
            await self?.completeObservedLaunch(sessionID: sessionID, taskID: taskID)
            await self?.removeReconciliationTask(taskKey)
        }
        reconciliationTasks[taskKey] = task
    }

    private func scheduleRelaunch(sessionID: SessionID) {
        let taskKey = UUID()
        let task = Task { [weak self] in
            await self?.relaunchAfterResynchronization(sessionID: sessionID)
            await self?.removeReconciliationTask(taskKey)
        }
        reconciliationTasks[taskKey] = task
    }

    private func removeReconciliationTask(_ taskKey: UUID) {
        reconciliationTasks[taskKey] = nil
    }

    private func completeObservedLaunch(sessionID: SessionID, taskID: Int32) async {
        guard await acquireOperation() else {
            return
        }
        defer { releaseOperation() }

        guard let current = await registry.session(sessionID),
            current.state == .launching,
            current.taskIDs.contains(taskID),
            !isShuttingDown
        else {
            return
        }
        do throws(SessionRegistryFailure) {
            _ = try await registry.transition(sessionID, to: .running)
        } catch {
            if let latest = await registry.session(sessionID), Self.isEnded(latest.state) {
                await stopDrainingFrames(for: sessionID)
                await forgetSession(packageID: current.packageID, sessionID: sessionID)
            }
        }
    }

    private func relaunchAfterResynchronization(sessionID: SessionID) async {
        guard await acquireOperation() else {
            return
        }
        defer { releaseOperation() }

        guard let current = await registry.session(sessionID),
            current.state == .launching,
            current.taskIDs.isEmpty,
            !isShuttingDown
        else {
            return
        }
        let report: GuestLaunchReport
        do throws(GuestAgentFailure) {
            report = try await guestAgent.launch(package: current.packageID, displayID: current.displayID)
        } catch {
            if !isShuttingDown, !Self.isTransientLaunchFailure(error) {
                await endFailedLaunch(sessionID)
            }
            return
        }
        guard !isShuttingDown else {
            return
        }

        let completed = await registry.launchCompleted(packageID: current.packageID, taskID: report.taskID)
        let latest: AppSessionSnapshot
        if let completed {
            latest = completed
        } else if let session = await registry.session(sessionID) {
            latest = session
        } else {
            return
        }
        guard !Self.isEnded(latest.state) else {
            await stopDrainingFrames(for: sessionID)
            await forgetSession(packageID: current.packageID, sessionID: sessionID)
            return
        }
        guard latest.state == .launching else {
            return
        }
        do throws(SessionRegistryFailure) {
            _ = try await registry.transition(sessionID, to: .running)
        } catch {
            if let session = await registry.session(sessionID), Self.isEnded(session.state) {
                await stopDrainingFrames(for: sessionID)
                await forgetSession(packageID: current.packageID, sessionID: sessionID)
            }
        }
    }

    private func startDrainingFrames(from lease: DisplayLease) {
        guard frameDrainers[lease.session] == nil else {
            return
        }
        let pool = lease.pool
        let sessionID = lease.session
        frameDrainers[sessionID] = Task.detached { [weak self] in
            for await frame in pool.frames {
                guard !Task.isCancelled else {
                    return
                }
                if case .frameReady(_, _, let sequence) = frame {
                    await self?.recordReadyFrameForTesting(sessionID, sequence: sequence)
                    pool.frameDisplayed(sequence: sequence)
                    await self?.noteFirstFrame(of: lease.session)
                }
            }
        }
    }

    func hasReadyFrameForTesting(sessionID: UUID) -> Bool {
        sessionsWithReadyFrameForTesting.contains(sessionID)
    }

    func launchComponentForTesting(sessionID: UUID) -> String? {
        launchComponentsForTesting[sessionID]
    }

    private func recordReadyFrameForTesting(_ session: SessionID, sequence: UInt64) {
        guard case .app(let sessionID) = session,
            let watermark = readyFrameSequenceWatermarksForTesting[sessionID],
            sequence > watermark
        else {
            return
        }
        readyFrameSequenceWatermarksForTesting.removeValue(forKey: sessionID)
        sessionsWithReadyFrameForTesting.insert(sessionID)
    }

    private func stopDrainingFrames(for sessionID: SessionID) async {
        guard let task = frameDrainers.removeValue(forKey: sessionID) else {
            return
        }
        task.cancel()
        await task.value
        if case .app(let appSessionID) = sessionID {
            readyFrameSequenceWatermarksForTesting.removeValue(forKey: appSessionID)
        }
    }

    private func endFailedLaunch(_ sessionID: SessionID) async {
        await stopDrainingFrames(for: sessionID)
        guard let current = await registry.session(sessionID) else {
            return
        }
        if !Self.isEnded(current.state) {
            _ = try? await registry.transition(sessionID, to: .ended(.error(.runtimeFailed)))
        }
        await forgetSession(packageID: current.packageID, sessionID: sessionID)
    }

    private func forgetSession(packageID: String, sessionID: SessionID, reason: String = "ended") async {
        if sessionsByPackage[packageID] == sessionID {
            sessionsByPackage[packageID] = nil
            if case .app(let appSessionID) = sessionID {
                readyFrameSequenceWatermarksForTesting.removeValue(forKey: appSessionID)
                sessionsWithReadyFrameForTesting.remove(appSessionID)
                launchComponentsForTesting.removeValue(forKey: appSessionID)
            }
            await onSessionEnded(packageID)
        }
        frameRateSamples[sessionID] = nil
        firstFrameMarked.remove(sessionID)
        lastSessionEndAt[packageID] = .now
        sessionEndedObserver?(sessionID, reason)
        noteActivity(packageID, .ended)
    }

    /// GU4: the package's last session end, tracked here because
    /// `AppSessionSnapshot` carries no timestamps.
    private var lastSessionEndAt: [String: ContinuousClock.Instant] = [:]

    func lastSessionEnd(packageID: RuntimePackageID) async -> ContinuousClock.Instant? {
        lastSessionEndAt[packageID.rawValue]
    }

    /// §7.3 Update Now: close the live session with the updating reason;
    /// the Android process may keep running — only the session ends.
    /// `reason` is `.runtimeUpdating` for an image migration (§12.3).
    func endSessionForUpdate(packageID: RuntimePackageID, reason: SessionEndReason = .updating) async {
        guard let current = await registry.session(packageID: packageID.rawValue) else { return }
        if current.state != .closing, !Self.isEnded(current.state) {
            _ = try? await registry.transition(current.id, to: .closing)
        }
        await stopDrainingFrames(for: current.id)
        _ = try? await registry.transition(current.id, to: .ended(reason))
        await forgetSession(packageID: packageID.rawValue, sessionID: current.id, reason: "updating")
    }

    /// §7.3 Update Now: relaunch the package after the install.
    func reopenPackageSession(packageID: RuntimePackageID) async throws {
        _ = try await launch(RuntimeLaunchRequest(packageID: packageID))
    }

    /// GU3: keepRunning-retained task IDs per package (update-system.md
    /// §7.1). A keepRunning close seeds it with the session's task IDs and
    /// task events grow and shrink it; the hold ends when the last retained
    /// task of the package ends.
    private var backgroundTasks: [String: Set<Int32>] = [:]

    /// §7.2 trigger observers, retained for the service's life.
    private var sessionActivityObservers: [@Sendable (RuntimePackageID, PackageSessionActivity) -> Void] = []

    /// Marks `taskIDs` of `packageID` as keepRunning-retained (a
    /// `window.closeBehavior = keepRunning` close keeps those tasks alive).
    func retainBackgroundTasks(_ packageID: String, taskIDs: Set<Int32>) {
        backgroundTasks[packageID, default: []].formUnion(taskIDs)
    }

    /// Ends `taskID`'s retention. Ending the last retained task is a §7.2
    /// gate trigger; a vanish matching no tracked task keeps the hold while
    /// other retained tasks remain.
    func endBackgroundTask(_ packageID: String, taskID: Int32) {
        guard var retained = backgroundTasks[packageID] else { return }
        retained.remove(taskID)
        if retained.isEmpty {
            backgroundTasks.removeValue(forKey: packageID)
            noteActivity(packageID, .taskEnded)
        } else {
            backgroundTasks[packageID] = retained
        }
    }

    /// Ends every retained task of `packageID` (terminate, uninstall,
    /// relaunch).
    func endAllBackgroundTasks(_ packageID: String) {
        if backgroundTasks.removeValue(forKey: packageID) != nil {
            noteActivity(packageID, .taskEnded)
        }
    }

    func hasBackgroundActivity(packageID: RuntimePackageID) async -> Bool {
        backgroundTasks[packageID.rawValue] != nil
    }

    /// Package IDs of all sessions that have not ended (§3.6 status).
    func maintenanceSessionPackageIDs() -> [RuntimePackageID] {
        sessionsByPackage.keys.sorted().compactMap { RuntimePackageID(rawValue: $0) }
    }

    /// Package IDs with a keepRunning background task (§3.6 status).
    func maintenanceBackgroundTaskPackageIDs() -> [RuntimePackageID] {
        backgroundTasks.keys.sorted().compactMap { RuntimePackageID(rawValue: $0) }
    }

    func observeSessionActivity(
        _ observer: @escaping @Sendable (RuntimePackageID, PackageSessionActivity) -> Void
    ) {
        sessionActivityObservers.append(observer)
    }

    private func noteActivity(_ packageID: String, _ activity: PackageSessionActivity) {
        guard let wireID = RuntimePackageID(rawValue: packageID) else { return }
        for observer in sessionActivityObservers {
            observer(wireID, activity)
        }
    }

    /// The package of a live app session, for session-channel routing
    /// (desktop-integration.md §3.3).
    public func packageID(forSession sessionID: UUID) -> String? {
        sessionsByPackage.first { $0.value == .app(sessionID) }?.key
    }

    /// Whether the package has a live session, for `integrationStatus`.
    public func hasLiveSession(packageID: String) -> Bool {
        sessionsByPackage[packageID] != nil
    }

    /// Installs the daemon's perf hooks once (idempotent; diagnostics.md §4.3).
    public func setPerfObservers(
        firstFrame: @escaping @Sendable (SessionID) -> Void,
        sessionEnded: @escaping @Sendable (SessionID, String) -> Void
    ) {
        guard firstFrameObserver == nil else {
            return
        }
        firstFrameObserver = firstFrame
        sessionEndedObserver = sessionEnded
    }

    /// The `session` attribute of `FIRST_FRAME_DISPLAYED`, comparable with a
    /// launch record's `sessionID` (diagnostics.md §4.2).
    private static func sessionAttribute(_ session: SessionID) -> String {
        switch session {
        case .app(let id):
            return id.uuidString
        case .system(let use):
            return "system:\(use)"
        }
    }

    /// Marks `FIRST_FRAME_DISPLAYED` once for a session and notifies the observer
    /// (diagnostics.md §4.2, §4.3).
    private func noteFirstFrame(of session: SessionID) {
        guard !firstFrameMarked.contains(session) else {
            return
        }
        firstFrameMarked.insert(session)
        Perf.mark(
            .firstFrameDisplayed,
            ["session": .string(Self.sessionAttribute(session))]
        )
        firstFrameObserver?(session)
        // §7.2: the first frame of a session that waited on a committing
        // update is that update's H4.
        if let package = sessionsByPackage.first(where: { $0.value == session })?.key,
            postUpdateLaunchPackages.remove(package) != nil,
            let wireID = RuntimePackageID(rawValue: package),
            let postUpdateFirstFrameObserver
        {
            Task { await postUpdateFirstFrameObserver(wireID) }
        }
    }

    /// Called by the host's §7.2 waiter when a launching session waited on
    /// a committing update install; the next first frame is the update's
    /// H4. `packageID` is the Android package identifier (raw).
    func markPostUpdateLaunch(_ packageID: String) {
        postUpdateLaunchPackages.insert(packageID)
    }

    /// The graphics statistics of every live session, for `frameStatistics` and
    /// `perfStatistics` (diagnostics.md §9.3, runtime-api.md §13.1).
    public func sessionGraphicsStatistics() async
        -> [(sessionID: UUID, statistics: SessionGraphicsStatistics)]
    {
        let counters = await displayPool.graphicsCounters()
        let now = ContinuousClock.now
        var rows: [(sessionID: UUID, statistics: SessionGraphicsStatistics)] = []
        for snapshot in await registry.snapshot() where !Self.isEnded(snapshot.state) {
            guard
                let lease = await registry.displayLease(snapshot.id),
                let wirePackageID = RuntimePackageID(rawValue: snapshot.packageID)
            else {
                continue
            }
            let present = await displayPool.presentStatistics(lease.scanout)
            let durations = (present?.durationsUs ?? []).sorted()
            let p50 = durations.isEmpty ? 0 : Int64(durations[durations.count / 2])
            let p95 =
                durations.isEmpty
                ? 0
                : Int64(durations[min(durations.count - 1, (durations.count * 95 + 99) / 100 - 1)])
            let frames = present?.statistics.framesPresented ?? 0
            var samples = frameRateSamples[snapshot.id] ?? []
            samples.append((time: now, frames: frames))
            samples = samples.filter { (now - $0.time) <= .seconds(10) }
            frameRateSamples[snapshot.id] = samples
            var fps = 0.0
            if let first = samples.first, let last = samples.last, last.time > first.time {
                let elapsed = (last.time - first.time).components
                let seconds =
                    Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                if seconds > 0 {
                    fps = Double(last.frames - first.frames) / seconds
                }
            }
            guard case .app(let sessionUUID) = snapshot.id else {
                continue
            }
            rows.append(
                (
                    sessionID: sessionUUID,
                    statistics: SessionGraphicsStatistics(
                        packageID: wirePackageID,
                        displayID: lease.androidDisplayID,
                        fps: fps,
                        droppedFrames: present?.statistics.droppedFrames ?? 0,
                        hostReadbacks: counters.hostReadbacks,
                        cpuPixelCopies: counters.cpuPixelCopies,
                        presentGPUTimeP50Us: p50,
                        presentGPUTimeP95Us: p95
                    )
                ))
        }
        return rows
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty || activeResynchronizations > 0 {
            operationInFlight = false
            let waiters = shutdownWaiters
            shutdownWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    private func finishResynchronization() {
        activeResynchronizations -= 1
        guard activeResynchronizations == 0 else {
            return
        }
        let waiters = resynchronizationWaiters
        resynchronizationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !operationInFlight, !operationWaiters.isEmpty else {
            return
        }
        operationInFlight = true
        operationWaiters.removeFirst().resume()
    }

    private func waitForResynchronizationsToFinish() async {
        guard activeResynchronizations > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            resynchronizationWaiters.append(continuation)
        }
    }

    private func waitForOperationsToFinish() async {
        guard operationInFlight else {
            return
        }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    private func acquireOperation() async -> Bool {
        guard !isShuttingDown, !Task.isCancelled else {
            return false
        }
        if !operationInFlight, activeResynchronizations == 0 {
            operationInFlight = true
            return true
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
        guard !isShuttingDown, !Task.isCancelled else {
            releaseOperation()
            return false
        }
        return true
    }

    private static let shuttingDownError = RuntimeWireError.runtime(
        "hostShuttingDown",
        message: "The app session service is shutting down.",
        remediation: "Try again after the runtime has started."
    )

    private static func launchResult(for session: AppSessionSnapshot) throws(RuntimeWireError) -> RuntimeLaunchResult {
        guard case .app(let sessionID) = session.id,
            let packageID = RuntimePackageID(rawValue: session.packageID)
        else {
            throw .runtime("internal", message: "APKRun could not identify the app session.")
        }
        let phase: RuntimeSessionPhase
        switch session.state {
        case .running, .backgrounded: phase = .running
        case .launching: phase = .launching
        case .requested: phase = .starting
        case .waitingForRuntime: phase = .booting
        case .acquiringDisplay: phase = .waitingForPackage
        case .closing, .ended: phase = .ended
        }
        return RuntimeLaunchResult(sessionID: sessionID, packageID: packageID, state: phase)
    }

    private static func isEnded(_ state: AppSessionState) -> Bool {
        if case .ended = state { true } else { false }
    }

    private static func isTransientLaunchFailure(_ failure: GuestAgentFailure) -> Bool {
        switch failure {
        case .connectTimedOut:
            true
        case .operationFailed(let reason):
            reason == "disconnected"
                || reason == "handshakeTimedOut"
                || reason.hasPrefix("timeout.")
                || reason.hasPrefix("agentUnavailable.")
        case .bundleMissing, .installFailed, .startFailed, .stopped, .handshakeFailed, .requiredAgentUnavailable, .adb:
            false
        }
    }

    private static let defaultDisplayConfiguration = DisplayConfiguration(
        geometry: DisplayGeometry(
            pointSize: CGSize(width: 480, height: 850),
            backingScale: 1
        )
    )

    /// Snapshots of all sessions that have not ended (host-ui.md §5.2).
    func sessionSnapshots() async -> [AppSessionSnapshot] {
        await registry.snapshot().filter { !$0.state.isEnded }
    }

    /// Registers the callback invoked for every committed session change.
    func setSessionChangeObserver(_ handler: (@Sendable (AppSessionSnapshot) -> Void)?) async {
        await registry.setOnChange(handler)
    }

    private static func wireError(for failure: SessionRegistryFailure) -> RuntimeWireError {
        switch failure {
        case .invalidPackageIdentifier:
            .runtime("invalidPackageID", message: "The Android package identifier is invalid.")
        case .displayInUse(let packageID):
            .runtime(
                "primaryDisplayBusy",
                message: "\(packageID) is already using the compatibility window mode.",
                remediation: "Close \(packageID) or switch it to the standard secondary display mode."
            )
        case .sessionAlreadyExists(let packageID):
            .runtime(
                "sessionAlreadyExists",
                message: "\(packageID) already has a live app session on another display.",
                remediation: "Close its current app session before requesting another display."
            )
        case .displayPool(let failure):
            wireError(for: failure)
        case .sessionNotFound, .invalidTransition:
            .runtime("internal", message: "The app session is in an invalid state.")
        }
    }

    private static func wireError(for failure: DisplayPoolFailure) -> RuntimeWireError {
        switch failure {
        case .exhausted:
            .runtime(
                "displayPoolExhausted",
                message: "APKRun could not allocate an Android app display.",
                remediation: "Close another Android app window and retry."
            )
        case .attachFailed:
            .runtime(
                "displayAttachFailed",
                message: "Android couldn't create a window for the app.",
                remediation: "Restart Android. If it happens again, create a diagnostics report."
            )
        case .staleLease:
            .runtime("internal", message: "The Android display lease is no longer current.")
        case .invalidGeometry:
            .runtime("displayGeometryInvalid", message: "The requested app window size is invalid.")
        case .reconfigureFailed(let stateUncertain):
            .runtime(
                "displayReconfigureFailed",
                message: "Android did not confirm the requested app window size.",
                remediation: stateUncertain
                    ? "Restart Android before reusing this display."
                    : "The previous display mode was restored. Try resizing again."
            )
        case .guest(.unavailable):
            .runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent is unavailable.",
                remediation: "Boot Android with the development Guest Agent, then retry."
            )
        case .guest(.operationFailed):
            .runtime(
                "guestAgentOperationFailed",
                message: "The Android Guest Agent could not apply the display policy.",
                remediation: "Restart Android and try again."
            )
        case .graphics(let failure):
            RuntimeWireError(
                domain: "graphics",
                code: "graphics.\(failure.code)",
                message: "APKRun couldn't prepare the graphics display.",
                remediation: "Restart Android. If the problem continues, create a diagnostics report."
            )
        case .primaryDisplayBusy:
            .runtime("primaryDisplayBusy", message: "Another app is already using the compatibility display.")
        case .primaryDisplayUnavailable:
            .runtime(
                "displayAttachFailed",
                message: "The compatibility display has no active graphics presenter."
            )
        }
    }

    static let guestTasksStillRunningError = RuntimeWireError.runtime(
        "guestAgentOperationFailed",
        message: "Android still reports tasks for this app.",
        remediation: "Wait for the app to close, then try again."
    )

    static let packageNotInstalledError = RuntimeWireError.runtime(
        "packageNotInstalled",
        message: "This app is not installed in Android.",
        remediation: "Install the app first, then try again."
    )

    static func wireError(for failure: GuestAgentFailure) -> RuntimeWireError {
        switch failure {
        case .bundleMissing:
            .runtime(
                "guestAgentBundleMissing",
                message: "APKRun can't find the Guest Agent for Android.",
                remediation: "Build the Guest Agent or restore the bundled agent, then try again."
            )
        case .installFailed(let reason):
            .runtime(
                "guestAgentInstallFailed",
                message: "Android didn't install the Guest Agent: \(reason).",
                remediation: "Check the install reason, fix Android, then try again."
            )
        case .startFailed:
            .runtime(
                "guestAgentStartFailed",
                message: "The Guest Agent didn't start.",
                remediation: "Restart Android and try again."
            )
        case .connectTimedOut:
            .runtime(
                "guestAgentConnectTimedOut",
                message: "APKRun couldn't connect to the Guest Agent within 30 seconds.",
                remediation: "Restart Android and try again."
            )
        case .stopped:
            .runtime(
                "guestAgentStopped",
                message: "The Guest Agent start was stopped before it answered.",
                remediation: "Start Android again and retry."
            )
        case .handshakeFailed(let reason):
            .runtime(
                "guestAgentHandshakeFailed",
                message: "The Guest Agent refused the connection: \(reason).",
                remediation: "Update APKRun and Android so they use the same Guest Agent protocol."
            )
        case .requiredAgentUnavailable:
            .runtime(
                "requiredAgentUnavailable",
                message: "The Guest Agent in Android isn't available.",
                remediation: "Restart Android."
            )
        case .adb:
            .runtime(
                "guestAgentOperationFailed",
                message: "The Android Guest Agent could not complete the app operation.",
                remediation: "Check the Android runtime and try again."
            )
        case .operationFailed(let reason):
            .runtime(
                "guestAgentOperationFailed",
                message: "The Guest Agent didn't complete the request: \(reason).",
                remediation: "Try again. If it fails again, restart Android."
            )
        }
    }
}

protocol DaemonHeadlessGuestAgent: EmbeddedSessionGuestAgent {
    func taskEventStream() async -> AsyncStream<DevelopmentGuestTaskEvent>
}

extension DevelopmentGuestAgent: DaemonHeadlessGuestAgent {
    func taskEventStream() async -> AsyncStream<DevelopmentGuestTaskEvent> {
        taskEvents
    }
}
