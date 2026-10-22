import DiagnosticsCore
import Dispatch
import Foundation
import ImageCore
import RuntimeAPI
import RuntimeCore

typealias WireOperationID = RuntimeAPI.OperationID

protocol RuntimeHostPowerObserver: Sendable {
    func start() throws(PowerObserverFailure)
    func stop()
}

extension PowerObserver: RuntimeHostPowerObserver {}

typealias RuntimeHostPowerObserverFactory =
    @Sendable (@escaping PowerObserver.EventHandler) -> any RuntimeHostPowerObserver

/// Failures that prevent the daemon from accepting lifecycle operations.
public enum RuntimeHostError: Error, Equatable, Sendable {
    /// Startup has not initialized the daemon components.
    case notStarted
    /// Startup was invoked twice on one host object.
    case alreadyStarted
    /// A degraded startup step blocks this operation.
    case startupFailed(step: Int, code: String)
    /// The daemon could not take its instance lock.
    case runtimeFailure(RuntimeFailure)
    /// The active image or instance could not be used.
    case image(ImageFailure)
    /// Automatic launches are temporarily blocked after repeated unclean exits.
    case crashLoopActive
    /// The daemon is shutting down and no longer accepts lifecycle requests.
    case shuttingDown
    /// The requested lifecycle change is not valid in the current runtime state.
    case invalidTransition
    /// The Guest Agent bundle is missing or invalid.
    case guestAgentBundle(String)
    /// Runtime boot failed.
    case runtimeBoot(RuntimeBootFailure)
    /// The daemon lifecycle record could not be updated.
    case stateStore(DaemonStateStoreError)
}

private struct RuntimeTrackedOperation {
    let handle: OperationHandle
    let requestPayload: Data
    let packageMutationToken: UUID
    var snapshot: OperationSnapshot
    var isCancellable: Bool
    var task: Task<Void, Never>?
}

private struct PackageMutationActivity {
    let assertion: RuntimeActivityAssertion?
}

/// Composes the daemon's per-user runtime and owns it for the process lifetime.
///
/// The host acquires the same instance lock used by `apkrun dev`, records its process state,
/// opens the current image, and creates one RuntimeSupervisor. Runtime start remains on demand.
public actor RuntimeHost {
    nonisolated let eventHub = RuntimeEventHub()

    private let paths: APKRunPaths
    private let buildInfo: BuildInfo
    private let environment: [String: String]
    private let executableURL: URL
    private let adbHostPort: UInt16
    private let uncleanExitRecoveryOverride: (any DaemonUncleanExitRecovering)?
    private let idleSettingsOverride: RuntimeIdleSettings?
    private let idleClock: any RuntimeIdleClock
    private var diagnostics: DiagnosticsContext?
    private var logger: APKLogger?
    private var instanceLock: InstanceLock?
    private var stateStore: DaemonStateStore?
    private var startupAssessment: DaemonStartupAssessment?
    private var image: InstalledImage?
    private var instanceStore: InstanceStore?
    private var supervisor: RuntimeSupervisor?
    private var supervisorEventsTask: Task<Void, Never>?
    private var idleSettings = RuntimeIdleSettings.default
    private var idleController: IdleController?
    private var packageStoreMutationTestGate: (@Sendable () async -> Void)?
    private var sessionActivityAssertions: [String: RuntimeActivityAssertion] = [:]
    private var adbClientActivityAssertion: RuntimeActivityAssertion?
    private var adbClientActivityTracker = ADBClientActivityTracker()
    private var isAcquiringADBClientActivity = false
    private var packageMutationActivities: [UUID: PackageMutationActivity] = [:]
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var prebootTask: Task<Void, Never>?
    private var powerEventHandler: PowerObserver.EventHandler?
    private var powerObserver: (any RuntimeHostPowerObserver)?
    private var powerObserverFactory: RuntimeHostPowerObserverFactory = { handler in
        PowerObserver(handler: handler)
    }
    private var packageQueryService: EmbeddedPackageService?
    private var headlessSessionService: (any RuntimeSessionService)?
    private var runtimeSessionGeneration: UInt64 = 0
    private var bootProgressEstimator: BootProgressEstimator?
    private var bootStartedAt: ContinuousClock.Instant?
    private var bootPurpose: RuntimeAPI.BootPurpose?
    private var bootProgressGeneration: UInt64 = 0
    private var runtimeStateSnapshotRevision: UInt64 = 0
    private var runtimeStateEventRevision: UInt64 = 0
    private var runtimeStateSnapshot: RuntimeState = .stopped
    private var recordedBootOperationIDs = Set<UUID>()
    private var hostState = "starting"
    private var startupFailure: (step: Int, code: String)?
    private var hasStarted = false
    private var startupCompleted = false
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShuttingDown = false
    private var shutdownCompleted = false
    private var activeLifecycleOperations = 0
    private var activeRuntimeStarts = 0
    private var activePackageMutations = 0
    private var idleSuspendTransitionInProgress = false
    private var idleSuspendTransitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var runtimeStartTask: Task<Result<Void, RuntimeHostError>, Never>?
    private var isRuntimeStopping = false
    private var isRuntimeResetting = false
    private var isRuntimeRestarting = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var packageMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var trackedOperations: [WireOperationID: RuntimeTrackedOperation] = [:]
    private var packageActivityReservations = PackageActivityReservations()

    /// Creates a daemon host for the current user.
    public init(
        paths: APKRunPaths = APKRunPaths(),
        buildInfo: BuildInfo = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "apkrund"),
        uncleanExitRecovery: (any DaemonUncleanExitRecovering)? = nil,
        adbHostPort: UInt16 = BootOptions.defaultADBHostPort,
        idleSettings: RuntimeIdleSettings? = nil,
        idleClock: any RuntimeIdleClock = SuspendingRuntimeIdleClock()
    ) {
        self.paths = paths
        self.buildInfo = buildInfo
        self.environment = environment
        self.executableURL = executableURL
        self.adbHostPort = adbHostPort
        uncleanExitRecoveryOverride = uncleanExitRecovery
        idleSettingsOverride = idleSettings
        self.idleClock = idleClock
    }

    /// Performs daemon startup. The LaunchAgent listener is published after the instance lock and
    /// run record are ready, but before image-store recovery. Missing image or Guest Agent data
    /// leaves the daemon degraded so it can still report a useful status to clients.
    public func start(
        publishListener: @Sendable () throws(RuntimeHostError) -> ContinuousClock.Instant
    ) async throws(RuntimeHostError) {
        guard !hasStarted else {
            throw .alreadyStarted
        }
        guard !isShuttingDown else {
            throw .shuttingDown
        }
        hasStarted = true
        activeLifecycleOperations += 1
        defer {
            if !startupCompleted {
                if hostState == "starting" {
                    hostState = "degraded"
                    if startupFailure == nil {
                        startupFailure = (step: 11, code: "runtime.serviceUnavailable")
                    }
                }
                completeStartup()
            }
            finishLifecycleOperation()
        }

        // Startup step 1: create the shared diagnostics dependencies before module construction.
        let diagnostics = DiagnosticsContext.live(paths: paths)
        self.diagnostics = diagnostics
        let logger = APKLogger(category: RuntimeLogCategory.host, sink: diagnostics.logSink)
        self.logger = logger
        if let idleSettingsOverride {
            idleSettings = idleSettingsOverride
        } else {
            do {
                idleSettings = try RuntimeIdleSettingsLoader.load(from: paths.settingsFile)
            } catch {
                idleSettings = .default
                logger.warning(
                    "Runtime idle settings are invalid; using defaults",
                    errorCode: "runtime.idleSettingsInvalid"
                )
            }
        }
        let idleController = IdleController(settings: idleSettings, clock: idleClock) { [weak self] action in
            await self?.handleIdleAction(action)
        }
        self.idleController = idleController
        await idleController.start()
        recordedBootOperationIDs = Set(
            BootRecordLog.read(from: paths.bootPerformanceFile).map(\.operationID)
        )

        // Startup step 2: the kernel releases this lock automatically after a crash.
        do {
            instanceLock = try InstanceLock.acquire(
                paths: paths,
                owner: .apkrund,
                executablePath: executableURL.path
            )
        } catch let failure {
            if case .instanceLocked(owner: .apkrund) = failure {
                throw .runtimeFailure(failure)
            }
            recordDegradedStartup(step: 2, code: failure.qualifiedCode)
            logger.error("The runtime instance could not be acquired", errorCode: failure.qualifiedCode)
        }

        // Startup step 3: preserve the crash history, then mark this process as unclean until shutdown.
        if instanceLock != nil {
            let stateStore = DaemonStateStore(fileURL: paths.daemonStateFile)
            self.stateStore = stateStore
            do {
                let assessment = try stateStore.beginRun(
                    version: "\(buildInfo.marketingVersion) (\(buildInfo.buildNumber))"
                )
                startupAssessment = assessment
                if assessment.previousExitWasUnclean {
                    logger.fault("host.previousExitUnclean")
                }
                if assessment.crashLoopActive {
                    logger.error("Three unclean daemon exits occurred within ten minutes")
                }
            } catch {
                recordDegradedStartup(step: 3, code: "hostStartupFailed")
            }
        }

        // The broker must be available while image recovery runs. Preserve the time captured
        // immediately after NSXPCListener.resume() even though diagnostics were initialized first.
        let listenerReadyAt = try publishListener()
        markDaemonReady(at: listenerReadyAt)

        if startupAssessment?.previousExitWasUnclean == true {
            let recovery =
                uncleanExitRecoveryOverride
                ?? DaemonUncleanExitRecovery.live(
                    paths: paths,
                    buildInfo: buildInfo,
                    environment: environment
                )
            let result = await recovery.recover()
            if result.indexedCrashReport != nil {
                logger.notice("Indexed the previous apkrund crash report")
            }
            for issue in result.issues {
                logger.warning(
                    "Unclean-exit recovery step failed: \(issue.rawValue, .public)"
                )
            }
        }

        // Startup step 5: only the instance-lock owner may recover or mutate the image store.
        if instanceLock != nil {
            let images = ImageStore(paths: paths, trust: .standard(), diagnostics: diagnostics)
            do {
                try await images.removeOrphanedInstalls()
                let currentImage = try await images.current()
                try await images.verify(currentImage, depth: .quick)
                image = currentImage
                instanceStore = InstanceStore(paths: paths, diagnostics: diagnostics)
            } catch {
                recordDegradedStartup(step: 5, code: error.qualifiedCode)
            }
        }

        // Startup step 8: RuntimeCore is created once for the process, while Android remains stopped.
        if let image, let instanceStore {
            let guestDirectory = DevGuestAgentLocation.directory(
                guestDir: nil,
                environment: environment,
                executable: executableURL
            )
            do {
                let guestAgent = try GuestAgentBundle.load(directory: guestDirectory)
                let runtimeSupervisor = RuntimeSupervisor(
                    image: image,
                    instanceStore: instanceStore,
                    options: BootOptions(
                        gpuProfile: .drmVirgl,
                        developerMode: buildInfo.configuration == .debug,
                        captureLogcat: false,
                        adbHostPort: adbHostPort
                    ),
                    diagnostics: diagnostics,
                    guestAgentBundle: guestAgent,
                    guestAgentTimeout: .seconds(30),
                    adbClientConnectionCountChanged: { [weak self] generation, revision, connectionCount in
                        Task {
                            await self?.updateADBClientActivity(
                                generation: generation,
                                revision: revision,
                                connectionCount: connectionCount
                            )
                        }
                    }
                )
                supervisor = runtimeSupervisor
                observeSupervisorEvents(from: runtimeSupervisor)
                let powerLogger = APKLogger(category: RuntimeLogCategory.power, sink: diagnostics.logSink)
                let powerService = EmbeddedDeveloperService(supervisor: runtimeSupervisor) { message in
                    powerLogger.warning("\(message, .public)")
                }
                powerEventHandler = { event in
                    await powerService.receivePowerObserverEvent(event)
                }
            } catch {
                recordDegradedStartup(step: 8, code: error.qualifiedCode)
            }
        }

        guard !isShuttingDown else {
            completeStartup()
            return
        }
        hostState = startupFailure == nil ? "running" : "degraded"
        startPowerObserver()
        startMemoryPressureObserver()
        schedulePrebootIfNeeded()
        logger.notice("Daemon startup completed with host state \(hostState, .public)")
        completeStartup()
    }

    private func handleIdleAction(_ action: IdleControllerAction) async {
        switch action {
        case .activityBegan:
            do {
                try await startRuntime(reason: .automatic)
            } catch {
                logger?.warning(
                    "Android could not be made ready for active work",
                    errorCode: Self.runtimeHostErrorCode(error)
                )
            }
        case .suspend:
            _ = await handleSuspendAction(ignoringActivityKinds: [])
        case .stop:
            guard !isShuttingDown, !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting,
                activeRuntimeStarts == 0, activePackageMutations == 0
            else {
                return
            }
            isRuntimeStopping = true
            defer { isRuntimeStopping = false }
            do {
                try await stopRuntimeBody(reason: .idle)
            } catch {
                logger?.error(
                    "The idle policy could not stop Android",
                    errorCode: Self.runtimeHostErrorCode(error)
                )
            }
        }
    }

    @discardableResult
    private func handleSuspendAction(ignoringActivityKinds: Set<RuntimeCore.ActivityKind>) async -> Bool {
        guard beginIdleSuspendTransition() else { return false }
        defer { finishIdleSuspendTransition() }

        guard !isShuttingDown, let idleController, let supervisor, await supervisor.state == .ready else {
            return false
        }
        let blockingActivityKinds = await idleController.activeActivityKinds.subtracting(ignoringActivityKinds)
        guard blockingActivityKinds.isEmpty else { return false }
        if ignoringActivityKinds.contains(.session) {
            let hasVisibleSession: Bool
            if let sessionService = headlessSessionService as? DaemonHeadlessSessionService {
                hasVisibleSession = await sessionService.hasVisibleSession()
            } else {
                hasVisibleSession = false
            }
            guard !hasVisibleSession,
                !(await idleController.hasActivity(of: .backgroundTask)),
                !packageActivityReservations.hasActiveLaunches
            else {
                return false
            }
        }
        do {
            try await supervisor.suspend()
            return true
        } catch {
            logger?.error(
                "The idle policy could not suspend Android",
                errorCode: error.qualifiedCode
            )
            return false
        }
    }

    private func beginIdleSuspendTransition() -> Bool {
        guard !idleSuspendTransitionInProgress else { return false }
        idleSuspendTransitionInProgress = true
        return true
    }

    private func finishIdleSuspendTransition() {
        idleSuspendTransitionInProgress = false
        let waiters = idleSuspendTransitionWaiters
        idleSuspendTransitionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForIdleSuspendTransition() async {
        guard idleSuspendTransitionInProgress else { return }
        await withCheckedContinuation { continuation in
            if idleSuspendTransitionInProgress {
                idleSuspendTransitionWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func startMemoryPressureObserver() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue(label: "io.apkrun.runtime.memory-pressure")
        )
        source.setEventHandler { [weak self, weak source] in
            guard let source else { return }
            let events = source.data
            let isWarning = events.contains(.warning)
            let isCritical = events.contains(.critical)
            Task {
                await self?.handleMemoryPressure(isWarning: isWarning, isCritical: isCritical)
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func handleMemoryPressure(isWarning: Bool, isCritical: Bool) async {
        if isWarning {
            logger?.warning(
                "runtime.memoryPressure is warning",
                errorCode: "runtime.memoryPressure.warning"
            )
        }
        guard isCritical, !isShuttingDown, let supervisor, await supervisor.state == .ready else {
            return
        }
        if await handleSuspendAction(ignoringActivityKinds: [.session]) {
            logger?.warning("runtime.memoryPressure is critical; the runtime was suspended")
        }
    }

    private func stopMemoryPressureObserver() {
        let source = memoryPressureSource
        memoryPressureSource = nil
        source?.setEventHandler {}
        source?.cancel()
    }

    private func schedulePrebootIfNeeded() {
        guard idleSettings.startPolicy == .atLogin, prebootTask == nil else { return }
        prebootTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.performConfiguredPreboot()
        }
    }

    private func performConfiguredPreboot() async {
        guard !isShuttingDown, idleSettings.startPolicy == .atLogin else { return }
        let bootLoopBlocked: Bool
        do {
            bootLoopBlocked = try stateStore?.bootLoopGuardIsActive() ?? false
        } catch {
            logger?.warning(
                "Preboot was skipped because the boot-loop guard could not be checked"
            )
            return
        }
        let powerSource = RuntimePrebootPolicy.currentPowerSourceState()
        guard
            RuntimePrebootPolicy.shouldPreboot(
                settings: idleSettings,
                bootLoopBlocked: bootLoopBlocked,
                powerSource: powerSource
            )
        else {
            if case .battery(let percentage) = powerSource, percentage < 30 {
                logger?.notice("Preboot was skipped because battery power is below 30 percent")
            }
            return
        }
        do {
            try await startRuntime(reason: .preboot)
        } catch {
            logger?.warning(
                "Configured preboot did not start Android",
                errorCode: Self.runtimeHostErrorCode(error)
            )
        }
    }

    private func releaseSessionActivity(_ packageID: String) {
        sessionActivityAssertions.removeValue(forKey: packageID)?.release()
    }

    private func releaseSessionActivityIfInactive(_ packageID: RuntimePackageID) async {
        if let headlessSessionService {
            guard let sessionHandling = headlessSessionService as? any PackageMutationSessionHandling else {
                return
            }
            guard !(await sessionHandling.hasActiveSession(packageID: packageID)) else { return }
        }
        releaseSessionActivity(packageID.rawValue)
    }

    private func updateADBClientActivity(
        generation: UInt64,
        revision: UInt64,
        connectionCount: Int
    ) async {
        guard
            adbClientActivityTracker.receive(
                generation: generation,
                revision: revision,
                connectionCount: connectionCount
            )
        else { return }
        guard adbClientActivityTracker.connectionCount > 0 else {
            adbClientActivityAssertion?.release()
            adbClientActivityAssertion = nil
            return
        }
        guard !isShuttingDown, !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting else {
            return
        }
        guard adbClientActivityAssertion == nil, !isAcquiringADBClientActivity,
            let idleController
        else {
            return
        }
        isAcquiringADBClientActivity = true
        await waitForIdleSuspendTransition()
        guard adbClientActivityTracker.connectionCount > 0 else {
            isAcquiringADBClientActivity = false
            return
        }
        let assertion = await idleController.assertActivity(.adbClient)
        isAcquiringADBClientActivity = false
        guard adbClientActivityTracker.connectionCount > 0 else {
            assertion.release()
            return
        }
        if adbClientActivityAssertion == nil {
            adbClientActivityAssertion = assertion
        } else {
            assertion.release()
        }
    }

    private func releaseADBClientActivity() async {
        if let supervisor {
            let generation = await supervisor.developmentADBForwarderGeneration
            adbClientActivityTracker.invalidate(afterGeneration: generation)
        } else {
            adbClientActivityTracker.clearConnectionCount()
        }
        adbClientActivityAssertion?.release()
        adbClientActivityAssertion = nil
    }

    private func releaseAllSessionActivity() {
        let assertions = sessionActivityAssertions.values
        sessionActivityAssertions.removeAll()
        for assertion in assertions {
            assertion.release()
        }
    }

    private static func runtimeHostErrorCode(_ error: any Error) -> String {
        if let error = error as? any APKRunError {
            return error.qualifiedCode
        }
        return String(describing: error)
    }

    private func startPowerObserver() {
        guard !isShuttingDown, powerObserver == nil else { return }
        let observer = powerObserverFactory { [weak self] event in
            await self?.receivePowerObserverEvent(event)
        }
        do {
            try observer.start()
            powerObserver = observer
            logger?.notice("Registered for host sleep and wake events")
        } catch {
            observer.stop()
            logger?.warning("Host sleep and wake notifications could not be registered")
        }
    }

    private func receivePowerObserverEvent(_ event: PowerObserverEvent) async {
        await powerEventHandler?(event)
    }

    private func stopPowerObserver() {
        let observer = powerObserver
        powerObserver = nil
        observer?.stop()
        powerEventHandler = nil
    }

    func configurePowerObserverForTesting(factory: @escaping RuntimeHostPowerObserverFactory) {
        precondition(!hasStarted)
        powerObserverFactory = factory
    }

    func developmentADBHostPortForTesting() async -> UInt16? {
        await supervisor?.developmentADBHostPort
    }

    func hasReadyFrameForTesting(sessionID: UUID) async -> Bool {
        guard let service = headlessSessionService as? DaemonHeadlessSessionService else {
            return false
        }
        return await service.hasReadyFrameForTesting(sessionID: sessionID)
    }

    func launchComponentForTesting(sessionID: UUID) async -> String? {
        guard let service = headlessSessionService as? DaemonHeadlessSessionService else {
            return nil
        }
        return await service.launchComponentForTesting(sessionID: sessionID)
    }

    func performanceEventsForTesting() -> [PerfEvent] {
        diagnostics?.perfTimeline.snapshot() ?? []
    }

    func idleActivityKindsForTesting() async -> Set<RuntimeCore.ActivityKind> {
        await idleController?.activeActivityKinds ?? []
    }

    func assertRuntimeActivity(_ kind: RuntimeCore.ActivityKind) async -> RuntimeActivityAssertion? {
        guard !isShuttingDown, let idleController else {
            return nil
        }
        return await idleController.assertActivity(kind)
    }

    func configurePackageStoreMutationGateForTesting(_ gate: @escaping @Sendable () async -> Void) {
        precondition(!hasStarted)
        packageStoreMutationTestGate = gate
    }

    /// Boots Android on demand. An explicit start is allowed after the crash-loop guard activates.
    public func startRuntime(reason: StartReason = .user) async throws(RuntimeHostError) {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting else {
            throw .invalidTransition
        }
        await waitForIdleSuspendTransition()
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting else {
            throw .invalidTransition
        }
        activeRuntimeStarts += 1
        defer { activeRuntimeStarts -= 1 }
        try await startRuntimeBody(reason: reason)
    }

    private func startRuntimeForPackageMutation(reason: StartReason) async throws(RuntimeHostError) {
        guard activePackageMutations > 0 else {
            throw .invalidTransition
        }
        activeRuntimeStarts += 1
        defer { activeRuntimeStarts -= 1 }
        try await startRuntimeBody(reason: reason, allowingReservedPackageMutation: true)
    }

    private func startRuntimeBody(
        reason: StartReason,
        allowingReservedPackageMutation: Bool = false
    ) async throws(RuntimeHostError) {
        try await waitForStartupCompletion(allowingReservedPackageMutation: allowingReservedPackageMutation)
        try beginLifecycleOperation(allowingReservedPackageMutation: allowingReservedPackageMutation)
        defer { finishLifecycleOperation() }

        if let runtimeStartTask {
            try await runtimeStartTask.value.get()
            await idleController?.resetIdlePeriod()
            return
        }

        let task = Task { [weak self] () -> Result<Void, RuntimeHostError> in
            guard let self else { return .failure(.notStarted) }
            do {
                try await self.performRuntimeStart(
                    reason: reason,
                    allowingReservedPackageMutation: allowingReservedPackageMutation
                )
                return .success(())
            } catch let error as RuntimeHostError {
                return .failure(error)
            } catch {
                return .failure(.notStarted)
            }
        }
        runtimeStartTask = task
        defer { runtimeStartTask = nil }
        try await task.value.get()
        await idleController?.resetIdlePeriod()
    }

    private func performRuntimeStart(
        reason: StartReason,
        allowingReservedPackageMutation: Bool
    ) async throws(RuntimeHostError) {
        if let startupFailure {
            throw .startupFailed(step: startupFailure.step, code: startupFailure.code)
        }
        let crashLoopActive: Bool
        do {
            crashLoopActive = try stateStore?.bootLoopGuardIsActive() ?? false
        } catch {
            throw .stateStore(error)
        }
        if crashLoopActive {
            switch reason {
            case .cli, .user:
                guard let stateStore else { throw .notStarted }
                do {
                    try stateStore.clearBootLoopGuard()
                    if let assessment = startupAssessment {
                        let record = try stateStore.current() ?? assessment.record
                        startupAssessment = DaemonStartupAssessment(
                            previousExitWasUnclean: assessment.previousExitWasUnclean,
                            crashLoopActive: false,
                            record: record
                        )
                    }
                } catch {
                    throw .stateStore(error)
                }
                logger?.notice("The user explicitly cleared the runtime crash-loop guard")
            case .automatic, .preboot:
                throw .crashLoopActive
            }
        }
        guard let image, let instanceStore, let supervisor else {
            if let startupFailure {
                throw .startupFailed(step: startupFailure.step, code: startupFailure.code)
            }
            throw .image(.noCurrentImage)
        }
        if await supervisor.state == .ready {
            return
        }
        let instance: InstanceConfiguration
        do {
            if let existing = try await instanceStore.load(image: image) {
                instance = existing
            } else {
                instance = try await instanceStore.provision(image: image, sizing: .default)
            }
        } catch {
            throw .image(error)
        }
        guard !isShuttingDown || allowingReservedPackageMutation || activePackageMutations > 0 else {
            throw .shuttingDown
        }
        bootProgressEstimator = BootProgressEstimator(
            bootKind: instance.firstBootSettingsApplied ? "cold" : "firstBoot",
            history: progressHistory()
        )
        bootPurpose = instance.firstBootSettingsApplied ? .normal : .firstBoot
        bootStartedAt = ContinuousClock.now
        bootProgressGeneration &+= 1
        let progressGeneration = bootProgressGeneration
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                await self?.publishBootProgress(generation: progressGeneration)
            }
        }
        defer {
            progressTask.cancel()
            if bootProgressGeneration == progressGeneration {
                bootProgressGeneration &+= 1
                bootPurpose = nil
            }
        }
        do {
            try await supervisor.ensureReady(reason)
        } catch {
            bootStartedAt = nil
            bootProgressEstimator = nil
            if isShuttingDown {
                throw .shuttingDown
            }
            recordLatestFailedBootIfPresent()
            throw .runtimeBoot(error)
        }
        bootStartedAt = nil
        bootProgressEstimator = nil
        recordSuccessfulBootIfPresent()
    }

    /// Stops Android but keeps the daemon available for a later request.
    public func stopRuntime() async throws(RuntimeHostError) {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting, activeRuntimeStarts == 0,
            activePackageMutations == 0
        else {
            throw .invalidTransition
        }
        isRuntimeStopping = true
        defer { isRuntimeStopping = false }
        try await stopRuntimeBody(reason: .user)
    }

    /// Restarts Android under one reserved lifecycle transition.
    public func restartRuntime(reason: StartReason) async throws(RuntimeHostError) {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting, activeRuntimeStarts == 0,
            activePackageMutations == 0
        else {
            throw .invalidTransition
        }
        isRuntimeRestarting = true
        defer { isRuntimeRestarting = false }
        try await stopRuntimeBody(reason: .user)
        try await startRuntimeBody(reason: reason)
    }

    private func stopRuntimeBody(reason: StopReason) async throws(RuntimeHostError) {
        try await waitForStartupCompletion()
        try beginLifecycleOperation()
        defer { finishLifecycleOperation() }
        runtimeSessionGeneration &+= 1
        if let service = headlessSessionService as? DaemonHeadlessSessionService {
            await service.shutdown()
        }
        await supervisor?.stop(reason: reason)
        await packageQueryService?.detachRuntime()
        releaseAllSessionActivity()
        await releaseADBClientActivity()
        headlessSessionService = nil
    }

    /// Clears the automatic boot-loop guard without starting Android or deleting user data.
    public func resetRuntime() async throws(RuntimeHostError) -> RuntimeHostStatus {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting, activeRuntimeStarts == 0,
            activePackageMutations == 0
        else {
            throw .invalidTransition
        }
        isRuntimeResetting = true
        defer { isRuntimeResetting = false }
        try await waitForStartupCompletion()
        try beginLifecycleOperation()
        defer { finishLifecycleOperation() }

        if let runtimeState = await supervisor?.state, case .stopping(_) = runtimeState {
            throw .invalidTransition
        }
        guard !isShuttingDown else {
            throw .shuttingDown
        }
        let guardIsActive: Bool
        do {
            guardIsActive = try stateStore?.bootLoopGuardIsActive() ?? false
        } catch {
            throw .stateStore(error)
        }
        if guardIsActive {
            guard let stateStore else { throw .notStarted }
            do {
                try stateStore.clearBootLoopGuard()
                if let assessment = startupAssessment {
                    let record = try stateStore.current() ?? assessment.record
                    startupAssessment = DaemonStartupAssessment(
                        previousExitWasUnclean: assessment.previousExitWasUnclean,
                        crashLoopActive: false,
                        record: record
                    )
                }
            } catch {
                throw .stateStore(error)
            }
            logger?.notice("The user explicitly cleared the runtime crash-loop guard")
        }
        return await status()
    }

    /// Launches an app through the daemon-owned Guest Agent session path.
    ///
    /// Until the native launcher endpoint is available, this operation is enabled only by the
    /// Debug-only headless acceptance hook. The headless session owns a DisplayPool lease and
    /// leaves frame surfaces unconsumed.
    public func launch(_ request: RuntimeLaunchRequest) async throws(RuntimeWireError) -> RuntimeLaunchResult {
        await waitForIdleSuspendTransition()
        try beginPackageLaunch(request.packageID)
        defer { finishPackageLaunch(request.packageID) }
        guard headlessLaunchHookIsEnabled else {
            throw Self.launchUnavailableError
        }
        if sessionActivityAssertions[request.packageID.rawValue] == nil,
            let idleController
        {
            sessionActivityAssertions[request.packageID.rawValue] =
                await idleController.assertActivity(.session)
        }
        do {
            try await startRuntime(reason: .automatic)
        } catch {
            await releaseSessionActivityIfInactive(request.packageID)
            throw Self.sessionWireError(for: error)
        }
        do {
            try requirePackageLaunchAllowed(request.packageID)
            let service = try await makeHeadlessSessionService()
            try requirePackageLaunchAllowed(request.packageID)
            let result = try await service.launch(request)
            await releaseSessionActivityIfInactive(request.packageID)
            return result
        } catch {
            await releaseSessionActivityIfInactive(request.packageID)
            throw error
        }
    }

    /// Stops a package session through the daemon-owned Guest Agent.
    public func terminate(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError)
        -> RuntimeTerminateResult
    {
        guard let supervisor, await supervisor.state == .ready else {
            return RuntimeTerminateResult(packageID: request.packageID, hadSession: false)
        }
        if let headlessSessionService {
            let result = try await headlessSessionService.terminate(request)
            if result.hadSession {
                releaseSessionActivity(request.packageID.rawValue)
            }
            return result
        }
        guard let guestAgent = await supervisor.developmentGuestAgent else {
            throw Self.guestAgentUnavailableError
        }
        return try await DaemonHeadlessSessionService.terminateWithoutSession(
            request,
            using: guestAgent
        )
    }

    /// Imports and inspects APK files without starting Android.
    public func importPackage(
        _ request: RuntimeImportPackageRequest,
        files: [FileHandle]
    ) async throws(RuntimeWireError) -> RuntimeImportPreview {
        let service = packageQueryServiceInstance()
        try await service.open()
        return try await service.importPackage(request, files: files)
    }

    /// Starts Android on demand, attaches its package channel, and installs an inspected import.
    public func installImported(
        _ request: RuntimeInstallImportedRequest
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        let packageID = try await resolvePackageIDForInstall(request)
        try reservePackageInstall(packageID)
        let mutationToken: UUID
        do {
            mutationToken = try await beginPackageMutation()
        } catch {
            packageActivityReservations.finishInstall(packageID: packageID.rawValue)
            throw Self.sessionWireError(for: error)
        }
        defer {
            packageActivityReservations.finishInstall(packageID: packageID.rawValue)
            finishPackageMutation(mutationToken)
        }

        return try await performInstallImported(
            request,
            packageID: packageID,
            clientKind: nil,
            operationID: nil
        )
    }

    /// Begins a daemon-owned install and returns its handle before Android starts or installs the APK.
    ///
    /// The lifecycle reservation and operation record are created synchronously before the handle
    /// is returned. A repeated request with the same ID and payload joins the existing operation.
    func beginInstallImported(
        _ request: RuntimeInstallImportedRequest,
        operationID requestedID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async throws(RuntimeWireError) -> OperationHandle {
        let requestPayload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            requestPayload = try encoder.encode(request)
        } catch {
            throw .runtime(
                "malformedRequest",
                message: "APKRun's background service couldn't read the request."
            )
        }

        if let existing = trackedOperations[requestedID] {
            guard existing.handle.kind == .install, existing.requestPayload == requestPayload else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request."
                )
            }
            return existing.handle
        }

        let packageID: RuntimePackageID
        do {
            packageID = try await resolvePackageIDForInstall(request)
        } catch {
            if let existing = trackedOperations[requestedID] {
                guard existing.handle.kind == .install, existing.requestPayload == requestPayload else {
                    throw .runtime(
                        "malformedRequest",
                        message: "The operation ID is already being used for a different request."
                    )
                }
                return existing.handle
            }
            throw error
        }
        if let existing = trackedOperations[requestedID] {
            guard existing.handle.kind == .install, existing.requestPayload == requestPayload else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request."
                )
            }
            return existing.handle
        }
        try reservePackageInstall(packageID)
        let mutationToken: UUID
        do {
            mutationToken = try await beginPackageMutation()
        } catch {
            packageActivityReservations.finishInstall(packageID: packageID.rawValue)
            throw Self.sessionWireError(for: error)
        }

        let handle = OperationHandle(operationID: requestedID, kind: .install)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .install,
            packageID: packageID,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(stage: "startingRuntime", message: "Starting Android…")
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            packageMutationToken: mutationToken,
            snapshot: snapshot,
            isCancellable: true,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: requestedID)
        let task = Task { [weak self] in
            guard let self else { return }
            if let diagnosticsID = DiagnosticsCore.OperationID(wire: requestedID.wireValue) {
                let context = OperationContext(operationID: diagnosticsID)
                await OperationContext.$current.withValue(context) {
                    await self.runInstallOperation(
                        request,
                        packageID: packageID,
                        operationID: requestedID,
                        clientKind: clientKind
                    )
                }
            } else {
                await self.runInstallOperation(
                    request,
                    packageID: packageID,
                    operationID: requestedID,
                    clientKind: clientKind
                )
            }
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    /// Begins a daemon-owned uninstall or host-only forget and returns its handle immediately.
    func beginUninstallPackage(
        _ request: RuntimeUninstallPackageRequest,
        operationID requestedID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async throws(RuntimeWireError) -> OperationHandle {
        guard !request.options.forget || !request.options.keepData else {
            throw Self.incompatibleUninstallOptionsError
        }

        let requestPayload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            requestPayload = try encoder.encode(request)
        } catch {
            throw .runtime(
                "malformedRequest",
                message: "APKRun's background service couldn't read the request."
            )
        }

        if let existing = trackedOperations[requestedID] {
            guard existing.handle.kind == .uninstall, existing.requestPayload == requestPayload else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request."
                )
            }
            return existing.handle
        }

        do {
            if request.options.forget {
                try packageActivityReservations.beginForget(packageID: request.packageID.rawValue)
            } else {
                try packageActivityReservations.beginUninstall(packageID: request.packageID.rawValue)
            }
        } catch {
            throw Self.packageOperationInProgressError
        }
        let mutationToken: UUID
        do {
            mutationToken = try await beginPackageMutation(activity: request.options.forget ? nil : .storeOperation)
        } catch {
            if request.options.forget {
                packageActivityReservations.finishForget(packageID: request.packageID.rawValue)
            } else {
                packageActivityReservations.finishUninstall(packageID: request.packageID.rawValue)
            }
            throw Self.sessionWireError(for: error)
        }

        let handle = OperationHandle(operationID: requestedID, kind: .uninstall)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .uninstall,
            packageID: request.packageID,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(
                stage: request.options.forget ? "updatingStore" : "startingRuntime",
                message: request.options.forget ? "Updating APKRun's package store…" : "Starting Android…"
            )
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            packageMutationToken: mutationToken,
            snapshot: snapshot,
            isCancellable: true,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: requestedID)
        let task = Task { [weak self] in
            guard let self else { return }
            if let diagnosticsID = DiagnosticsCore.OperationID(wire: requestedID.wireValue) {
                let context = OperationContext(operationID: diagnosticsID)
                await OperationContext.$current.withValue(context) {
                    await self.runUninstallOperation(
                        request,
                        operationID: requestedID,
                        clientKind: clientKind
                    )
                }
            } else {
                await self.runUninstallOperation(request, operationID: requestedID, clientKind: clientKind)
            }
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    /// Returns running operations and up to fifty recently finished operations.
    func listOperations(
        beginSnapshotBarrier: @Sendable () -> Void = {}
    ) -> [OperationSnapshot] {
        beginSnapshotBarrier()
        return trackedOperations.values
            .map(\.snapshot)
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Returns a retained operation snapshot.
    func operationStatus(
        _ operationID: WireOperationID,
        beginSnapshotBarrier: @Sendable () -> Void = {}
    ) throws(RuntimeWireError) -> OperationSnapshot {
        guard let operation = trackedOperations[operationID] else {
            throw Self.operationNotFoundError
        }
        beginSnapshotBarrier()
        return operation.snapshot
    }

    /// Requests cancellation before an install or uninstall enters its guest transaction.
    func cancelOperation(_ operationID: WireOperationID) throws(RuntimeWireError) -> CancelReply {
        guard let operation = trackedOperations[operationID] else {
            throw Self.operationNotFoundError
        }
        if let result = operation.snapshot.result {
            return .alreadyFinished(result)
        }
        guard operation.isCancellable else {
            let reason =
                operation.handle.kind == .uninstall
                ? "Android package removal has started and will continue."
                : "Android package installation has started and will continue."
            return .notCancellable(reason: reason)
        }
        operation.task?.cancel()
        trackedOperations[operationID] = operation
        return .cancelling
    }

    private static let operationNotFoundError = RuntimeWireError.runtime(
        "operationNotFound",
        message: "That operation doesn't exist or has expired.",
        remediation: "List the current operations with: apkrun operations list"
    )

    private static let cancelledOperationError = RuntimeWireError.runtime(
        "cancelled",
        message: "The operation was cancelled."
    )

    private func runInstallOperation(
        _ request: RuntimeInstallImportedRequest,
        packageID: RuntimePackageID,
        operationID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async {
        let mutationToken = trackedOperations[operationID]?.packageMutationToken
        defer {
            packageActivityReservations.finishInstall(packageID: packageID.rawValue)
            if let mutationToken {
                finishPackageMutation(mutationToken)
            }
        }
        do {
            let result = try await performInstallImported(
                request,
                packageID: packageID,
                clientKind: clientKind,
                operationID: operationID
            )
            finishOperation(operationID, result: .succeeded(.package(result)))
            logger?.notice(
                "Package installation completed for \(result.packageID.rawValue, .public)"
            )
        } catch {
            if Task.isCancelled {
                finishOperation(operationID, result: .cancelled)
                logger?.notice("Package installation was cancelled")
                return
            }
            let wireError = Self.operationWireError(for: error)
            finishOperation(operationID, result: .failed(wireError))
            logger?.error("Package installation failed", errorCode: wireError.code)
        }
    }

    private func runUninstallOperation(
        _ request: RuntimeUninstallPackageRequest,
        operationID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async {
        let mutationToken = trackedOperations[operationID]?.packageMutationToken
        defer {
            if request.options.forget {
                packageActivityReservations.finishForget(packageID: request.packageID.rawValue)
            } else {
                packageActivityReservations.finishUninstall(packageID: request.packageID.rawValue)
            }
            if let mutationToken {
                finishPackageMutation(mutationToken)
            }
        }
        do {
            try await performUninstallPackage(
                request,
                clientKind: clientKind,
                operationID: operationID
            )
            finishOperation(operationID, result: .succeeded(.none))
            logger?.notice(
                "Package uninstall operation completed for \(request.packageID.rawValue, .public)"
            )
        } catch {
            if Task.isCancelled {
                finishOperation(operationID, result: .cancelled)
                logger?.notice("Package uninstall operation was cancelled")
                return
            }
            let wireError = Self.operationWireError(for: error)
            finishOperation(operationID, result: .failed(wireError))
            logger?.error("Package uninstall operation failed", errorCode: wireError.code)
        }
    }

    private func performInstallImported(
        _ request: RuntimeInstallImportedRequest,
        packageID: RuntimePackageID,
        clientKind: RuntimeClientKind?,
        operationID: WireOperationID?
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        let service = packageQueryServiceInstance()
        if let headlessSessionService {
            await service.setSessionService(headlessSessionService)
        }
        try await service.open()
        try await waitForPackageLaunches(packageID.rawValue)
        do {
            try Task.checkCancellation()
        } catch {
            throw Self.cancelledOperationError
        }

        do {
            try await startRuntimeForPackageMutation(reason: clientKind == .cli ? .cli : .user)
        } catch {
            throw Self.sessionWireError(for: error)
        }

        try await attachPackageQueriesIfRuntimeIsReady(to: service)
        if let headlessSessionService {
            await service.setSessionService(headlessSessionService)
        }
        let storeMutationBoundary: PackageMutationBoundary = { [weak self] () async throws(RuntimeWireError) in
            guard let self else { throw Self.cancelledOperationError }
            do {
                try await self.enterPackageStoreMutation(
                    operationID: operationID,
                    stage: "installing",
                    message: "Installing the Android package…"
                )
            } catch {
                throw Self.operationWireError(for: error)
            }
        }
        let installResult = try await service.installImportedWithChange(
            request,
            beforeStoreMutation: storeMutationBoundary
        )
        if installResult.cleanupDeferred {
            logger?.warning(
                "Package install committed; package-store cleanup is deferred",
                errorCode: "store.cleanupDeferred"
            )
        }
        eventHub.publishPackageChange(installResult.change, operationID: operationID)
        return installResult.summary
    }

    private func performUninstallPackage(
        _ request: RuntimeUninstallPackageRequest,
        clientKind: RuntimeClientKind,
        operationID: WireOperationID
    ) async throws(RuntimeWireError) {
        guard !request.options.forget || !request.options.keepData else {
            throw Self.incompatibleUninstallOptionsError
        }
        let service = packageQueryServiceInstance()
        if let headlessSessionService {
            await service.setSessionService(headlessSessionService)
        }
        try await service.open()
        do {
            try Task.checkCancellation()
        } catch {
            throw Self.cancelledOperationError
        }
        if !request.options.forget {
            try await waitForPackageLaunches(request.packageID.rawValue)
        }

        if !request.options.forget {
            do {
                try await startRuntimeForPackageMutation(reason: clientKind == .cli ? .cli : .user)
            } catch {
                throw Self.sessionWireError(for: error)
            }
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
            if let headlessSessionService {
                await service.setSessionService(headlessSessionService)
            }
            guard !Task.isCancelled else {
                throw Self.cancelledOperationError
            }
        }

        // Keep cancellation available while the app session closes. The boundary callback runs
        // immediately before PackageStore starts the guest uninstall or host-only forget.
        let storeMutationBoundary: PackageMutationBoundary = { [weak self] () async throws(RuntimeWireError) in
            guard let self else { throw Self.cancelledOperationError }
            do {
                try await self.enterPackageStoreMutation(
                    operationID: operationID,
                    stage: request.options.forget ? "updatingStore" : "uninstalling",
                    message: request.options.forget
                        ? "Updating APKRun's package store…"
                        : "Uninstalling the Android package…"
                )
            } catch {
                throw Self.operationWireError(for: error)
            }
        }
        let result = try await service.uninstallPackageWithChange(
            request,
            beforeStoreMutation: storeMutationBoundary
        )
        if result.cleanupDeferred {
            logger?.warning(
                "Package uninstall committed; package-store cleanup is deferred",
                errorCode: "store.cleanupDeferred"
            )
        }
        if let change = result.change {
            eventHub.publishPackageChange(change, operationID: operationID)
        }
    }

    private static func operationWireError(for error: any Error) -> RuntimeWireError {
        if let wireError = error as? RuntimeWireError {
            return wireError
        }
        if let hostError = error as? RuntimeHostError {
            return sessionWireError(for: hostError)
        }
        if error is CancellationError {
            return cancelledOperationError
        }
        return .runtime(
            "internal",
            message: "APKRun couldn't complete the package operation."
        )
    }

    private static let incompatibleUninstallOptionsError = RuntimeWireError.runtime(
        "malformedRequest",
        message: "A package cannot be forgotten while retaining its Android data.",
        remediation: "Choose either `--forget` or `--keep-data`, not both."
    )

    private func requirePackageLaunchAllowed(_ packageID: RuntimePackageID) throws(RuntimeWireError) {
        guard !packageActivityReservations.isUninstalling(packageID: packageID.rawValue),
            !packageActivityReservations.isInstalling(packageID: packageID.rawValue)
        else {
            throw Self.packageOperationInProgressError
        }
    }

    private func resolvePackageIDForInstall(
        _ request: RuntimeInstallImportedRequest
    ) async throws(RuntimeWireError) -> RuntimePackageID {
        let service = packageQueryServiceInstance()
        try await service.open()
        return try await service.packageIDForInstall(request)
    }

    private func reservePackageInstall(_ packageID: RuntimePackageID) throws(RuntimeWireError) {
        do {
            try packageActivityReservations.beginInstall(packageID: packageID.rawValue)
        } catch {
            throw Self.packageOperationInProgressError
        }
    }

    private func beginPackageLaunch(_ packageID: RuntimePackageID) throws(RuntimeWireError) {
        do {
            try packageActivityReservations.beginLaunch(packageID: packageID.rawValue)
        } catch {
            throw Self.packageOperationInProgressError
        }
    }

    private func finishPackageLaunch(_ packageID: RuntimePackageID) {
        packageActivityReservations.finishLaunch(packageID: packageID.rawValue)
    }

    private func waitForPackageLaunches(_ package: String) async throws(RuntimeWireError) {
        while packageActivityReservations.hasActiveLaunches(packageID: package) {
            guard !Task.isCancelled else {
                throw Self.cancelledOperationError
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw Self.cancelledOperationError
            }
        }
    }

    private static let packageOperationInProgressError = RuntimeWireError.store(
        "operationInProgress",
        message: "APKRun is already changing this app's package state.",
        remediation: "Wait for the package operation to finish, then try again."
    )

    private func setPackageMutationNotCancellable(
        _ operationID: WireOperationID,
        stage: String,
        message: String
    ) {
        guard var operation = trackedOperations[operationID], operation.snapshot.result == nil else {
            return
        }
        operation.isCancellable = false
        operation.snapshot = OperationSnapshot(
            operationID: operation.snapshot.operationID,
            parent: operation.snapshot.parent,
            kind: operation.snapshot.kind,
            packageID: operation.snapshot.packageID,
            requestFingerprint: operation.snapshot.requestFingerprint,
            clientKind: operation.snapshot.clientKind,
            startedAt: operation.snapshot.startedAt,
            progress: OperationProgress(
                stage: stage,
                message: message
            )
        )
        trackedOperations[operationID] = operation
        eventHub.publishOperationEvent(
            .progress(operationID, operation.snapshot.progress ?? OperationProgress()),
            operationID: operationID
        )
    }

    private func enterPackageStoreMutation(
        operationID: WireOperationID?,
        stage: String,
        message: String
    ) async throws(RuntimeWireError) {
        guard !Task.isCancelled else {
            throw Self.cancelledOperationError
        }
        await packageStoreMutationTestGate?()
        guard !Task.isCancelled else {
            throw Self.cancelledOperationError
        }
        if let operationID {
            // PackageStore reconciles ambiguous guest results and journals the transaction to a
            // terminal state once its Store Agent operation begins.
            setPackageMutationNotCancellable(operationID, stage: stage, message: message)
        }
    }

    private func finishOperation(_ operationID: WireOperationID, result: OperationResult) {
        guard var operation = trackedOperations[operationID], operation.snapshot.result == nil else {
            return
        }
        let packageID: RuntimePackageID?
        if case .succeeded(.package(let summary)) = result {
            packageID = summary.packageID
        } else {
            packageID = operation.snapshot.packageID
        }
        operation.task = nil
        operation.snapshot = OperationSnapshot(
            operationID: operation.snapshot.operationID,
            parent: operation.snapshot.parent,
            kind: operation.snapshot.kind,
            packageID: packageID,
            requestFingerprint: operation.snapshot.requestFingerprint,
            clientKind: operation.snapshot.clientKind,
            startedAt: operation.snapshot.startedAt,
            progress: operation.snapshot.progress,
            result: result,
            finishedAt: Date()
        )
        trackedOperations[operationID] = operation
        eventHub.publishOperationEvent(
            .finished(operationID, result),
            operationID: operationID
        )
        pruneFinishedOperations()
    }

    private func pruneFinishedOperations() {
        let finished = trackedOperations.values
            .filter { $0.snapshot.result != nil }
            .sorted {
                ($0.snapshot.finishedAt ?? .distantPast) < ($1.snapshot.finishedAt ?? .distantPast)
            }
        for operation in finished.dropLast(50) {
            trackedOperations[operation.handle.operationID] = nil
        }
    }

    /// Lists daemon-owned package records and, when requested, merges a live or cached Android inventory.
    ///
    /// The query never starts Android. A live inventory is used only while the supervisor is already ready.
    public func listPackages(
        _ request: RuntimeListPackagesRequest
    ) async throws(RuntimeWireError) -> RuntimePackageListResult {
        let service = packageQueryServiceInstance()
        try await service.open()
        if request.filter == .all {
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
        }
        return try await service.listPackages(request)
    }

    /// Reads package metadata from the daemon-owned store without starting Android.
    public func packageInfo(
        _ request: RuntimePackageRequest
    ) async throws(RuntimeWireError) -> RuntimePackageDetails {
        let service = packageQueryServiceInstance()
        try await service.open()
        try await attachPackageQueriesIfRuntimeIsReady(to: service)
        return try await service.packageInfo(request)
    }

    /// Returns a point-in-time view for the control endpoint.
    public func status() async -> RuntimeHostStatus {
        if let snapshot = await supervisor?.stateSnapshot() {
            synchronizeRuntimeStateSnapshot(snapshot)
        }
        let runtimeStateValue = runtimeStateSnapshot
        let guestAgentStatus = await supervisor?.guestAgentStatusSnapshot()
        let runtimeState = Self.describe(runtimeStateValue)
        let bootProgress: Double?
        if case .booting(let phase) = runtimeStateValue,
            let bootStartedAt,
            var estimator = bootProgressEstimator
        {
            bootProgress = estimator.fraction(
                phase: phase,
                elapsedSinceStart: bootStartedAt.duration(to: ContinuousClock.now)
            )
            bootProgressEstimator = estimator
        } else {
            bootProgress = nil
        }
        let guestAgentStateName: GuestAgentConnectionState?
        if let guestAgentStatus {
            switch guestAgentStatus.state {
            case .stopped: guestAgentStateName = .notStarted
            case .paused: guestAgentStateName = .unavailable
            case .connecting: guestAgentStateName = .connecting
            case .ready: guestAgentStateName = .connected
            case .reconnecting: guestAgentStateName = .reconnecting
            case .unresponsive: guestAgentStateName = .unresponsive
            case .incompatible: guestAgentStateName = .incompatible
            case .unavailable: guestAgentStateName = .unavailable
            }
        } else {
            guestAgentStateName = nil
        }
        let crashLoopActive = (try? stateStore?.bootLoopGuardIsActive()) ?? startupAssessment?.crashLoopActive ?? false
        return RuntimeHostStatus(
            hostState: hostState,
            runtimeState: runtimeState,
            bootProgress: bootProgress,
            startupFailureStep: startupFailure?.step,
            startupFailureCode: startupFailure?.code,
            crashLoopActive: crashLoopActive,
            daemonPID: Int32(getpid()),
            imageVersion: image?.version.description,
            guestAgentState: guestAgentStateName,
            guestAgentProtocolVersion: guestAgentStatus?.protocolVersion?.description
        )
    }

    /// Whether the daemon can exit after its idle grace period without cancelling an operation.
    public func canExitWhenIdle() async -> Bool {
        guard hasStarted, !isShuttingDown, activeLifecycleOperations == 0 else {
            return false
        }
        let runtimeState = await supervisor?.state
        return !isShuttingDown
            && activeLifecycleOperations == 0
            && (runtimeState == nil || runtimeState == .stopped)
    }

    private func observeSupervisorEvents(from supervisor: RuntimeSupervisor) {
        guard supervisorEventsTask == nil else { return }
        let events = supervisor.events
        supervisorEventsTask = Task.detached { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                guard case .state(let snapshot) = event else { continue }
                await self?.consumeSupervisorState(snapshot)
            }
        }
    }

    /// Advances the status cache without changing the ordered event-delivery cursor.
    func synchronizeRuntimeStateSnapshot(_ snapshot: RuntimeStateSnapshot) {
        guard snapshot.revision > runtimeStateSnapshotRevision else { return }
        runtimeStateSnapshotRevision = snapshot.revision
        runtimeStateSnapshot = snapshot.state
    }

    /// Publishes every supervisor state update once, even when a status snapshot has moved ahead.
    func consumeSupervisorState(_ snapshot: RuntimeStateSnapshot) {
        guard snapshot.revision > runtimeStateEventRevision else { return }
        runtimeStateEventRevision = snapshot.revision
        synchronizeRuntimeStateSnapshot(snapshot)
        eventHub.publishRuntimeChange(.stateChanged(Self.wireRuntimeState(for: snapshot.state)))
        if case .booting = snapshot.state {
            publishBootProgress(generation: bootProgressGeneration)
        }
    }

    private func publishBootProgress(generation: UInt64) {
        guard generation == bootProgressGeneration,
            case .booting(let phase) = runtimeStateSnapshot,
            let bootStartedAt,
            let bootPurpose,
            var estimator = bootProgressEstimator
        else {
            return
        }
        let elapsed = bootStartedAt.duration(to: ContinuousClock.now)
        let fraction = estimator.fraction(phase: phase, elapsedSinceStart: elapsed)
        bootProgressEstimator = estimator
        eventHub.publishRuntimeChange(
            .bootProgress(
                RuntimeAPI.BootProgress(
                    phase: Self.wireBootPhase(phase),
                    fraction: fraction,
                    elapsedMs: Self.milliseconds(elapsed),
                    purpose: bootPurpose
                )
            )
        )
    }

    static func wireRuntimeState(for state: RuntimeState) -> RuntimeAPI.WireRuntimeState {
        switch state {
        case .stopped:
            .stopped
        case .booting(let phase):
            .booting(wireBootPhase(phase))
        case .ready:
            .ready
        case .suspended:
            .suspended
        case .stopping(let reason):
            .stopping(wireStopReason(reason))
        case .failed(let failure):
            .failed(wireError(for: failure))
        }
    }

    private static func wireBootPhase(_ phase: RuntimeCore.BootPhase) -> RuntimeAPI.BootPhase {
        switch phase {
        case .kernel: .kernel
        case .`init`: .`init`
        case .systemServer: .systemServer
        case .bootCompleted: .bootCompleted
        case .agentsConnecting: .agentsConnecting
        }
    }

    private static func wireStopReason(_ reason: StopReason) -> RuntimeAPI.WireStopReason {
        switch reason {
        case .user: .user
        case .idle: .idle
        case .hostShutdown: .hostShutdown
        case .hostUpdate: .hostUpdate
        case .migration: .migration
        case .reset: .reset
        case .failure: .failure
        }
    }

    private static func wireError(
        for error: any APKRunError,
        depth: Int = 0
    ) -> RuntimeAPI.WireError {
        var parameters: [String: RuntimeAPI.WireErrorParameter] = [:]
        for (key, value) in error.parameters where key != "detail" {
            switch value {
            case .text(let text):
                parameters[key] = .text(text)
            case .bytes(let bytes):
                parameters[key] = .bytes(bytes)
            case .count(let count):
                parameters[key] = .count(count)
            case .duration(let duration):
                parameters[key] = .durationMs(Self.milliseconds(duration))
            case .fileName(let fileName):
                parameters[key] = .fileName(URL(fileURLWithPath: fileName).lastPathComponent)
            }
        }
        let listItems: [RuntimeAPI.WireErrorListItem]? =
            error.listItems.isEmpty
            ? nil
            : error.listItems.map { item in
                let selector: RuntimeAPI.WireErrorListItemSelector
                switch item.selector {
                case .errorCode(let code):
                    selector = .errorCode(code)
                case .variant(let code, let key):
                    selector = .variant(code: code, key: key)
                }
                var itemParameters: [String: RuntimeAPI.WireErrorParameter] = [:]
                for (key, value) in item.parameters {
                    switch value {
                    case .text(let text):
                        itemParameters[key] = .text(text)
                    case .bytes(let bytes):
                        itemParameters[key] = .bytes(bytes)
                    case .count(let count):
                        itemParameters[key] = .count(count)
                    case .duration(let duration):
                        itemParameters[key] = .durationMs(Self.milliseconds(duration))
                    case .fileName(let fileName):
                        itemParameters[key] = .fileName(URL(fileURLWithPath: fileName).lastPathComponent)
                    }
                }
                return RuntimeAPI.WireErrorListItem(selector: selector, parameters: itemParameters)
            }
        let cause: RuntimeAPI.WireErrorBox?
        if depth < 8, let nested = error.cause {
            cause = RuntimeAPI.WireErrorBox(wireError(for: nested, depth: depth + 1))
        } else {
            cause = nil
        }
        let underlying = error.underlying.map {
            RuntimeAPI.WireUnderlyingError(domain: $0.domain, code: $0.code)
        }
        return RuntimeAPI.WireError(
            domain: type(of: error).domain.rawValue,
            code: error.qualifiedCode,
            parameters: parameters,
            listItems: listItems,
            cause: cause,
            underlying: underlying
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let milliseconds =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return Int64(milliseconds)
    }

    /// Records the marker at the time the authenticated XPC endpoint began serving.
    private func markDaemonReady(at time: ContinuousClock.Instant) {
        guard let diagnostics else { return }
        Perf.mark(.daemonReady, at: time, timeline: diagnostics.perfTimeline)
        logger?.notice("Daemon control endpoint is ready")
    }

    /// Gracefully stops Android, records a clean daemon exit, and releases the instance lock.
    public func shutdown() async {
        guard !shutdownCompleted else { return }
        if isShuttingDown {
            await waitForShutdownCompletion()
            return
        }
        isShuttingDown = true
        runtimeSessionGeneration &+= 1
        hostState = "shuttingDown"
        prebootTask?.cancel()
        prebootTask = nil
        stopPowerObserver()
        stopMemoryPressureObserver()
        await idleController?.stop()
        await releaseADBClientActivity()
        guard hasStarted else {
            hostState = "stopped"
            completeShutdown()
            return
        }
        await waitForPackageMutations()
        if let service = headlessSessionService as? DaemonHeadlessSessionService {
            await service.shutdown()
        }
        releaseAllSessionActivity()
        headlessSessionService = nil
        // Mark an in-flight VM start for cancellation before waiting for any storage work to finish.
        await supervisor?.stop(reason: .hostShutdown)
        await waitForLifecycleOperations()
        stopPowerObserver()
        // A start that was already inside RuntimeSupervisor may have finished its cancellation path
        // while this actor was waiting. Stop once more before recording a clean process exit.
        await supervisor?.stop(reason: .hostShutdown)
        await releaseADBClientActivity()
        await supervisor?.finishEventStream()
        if let supervisorEventsTask {
            await supervisorEventsTask.value
            self.supervisorEventsTask = nil
        }
        if let stateStore {
            do {
                try stateStore.markCleanExit()
            } catch {
                logger?.error(
                    "Could not record a clean daemon exit",
                    errorCode: String(describing: error)
                )
            }
        }
        instanceLock?.close()
        instanceLock = nil
        hostState = "stopped"
        hasStarted = false
        completeShutdown()
    }

    private func beginLifecycleOperation(
        allowingReservedPackageMutation: Bool = false
    ) throws(RuntimeHostError) {
        guard hasStarted else {
            throw .notStarted
        }
        guard !isShuttingDown || allowingReservedPackageMutation && activePackageMutations > 0 else {
            throw .shuttingDown
        }
        activeLifecycleOperations += 1
    }

    private func finishLifecycleOperation() {
        activeLifecycleOperations -= 1
        guard activeLifecycleOperations == 0 else { return }
        let waiters = lifecycleWaiters
        lifecycleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func beginPackageMutation(
        activity: RuntimeCore.ActivityKind? = .storeOperation
    ) async throws(RuntimeHostError) -> UUID {
        await waitForIdleSuspendTransition()
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting else {
            throw .invalidTransition
        }
        try beginLifecycleOperation()
        activePackageMutations += 1
        let assertion: RuntimeActivityAssertion?
        if let activity, let idleController {
            assertion = await idleController.assertActivity(activity)
        } else {
            assertion = nil
        }
        let token = UUID()
        packageMutationActivities[token] = PackageMutationActivity(assertion: assertion)
        return token
    }

    private func finishPackageMutation(_ token: UUID) {
        let activity = packageMutationActivities.removeValue(forKey: token)
        activePackageMutations -= 1
        activity?.assertion?.release()
        if activePackageMutations == 0 {
            let waiters = packageMutationWaiters
            packageMutationWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        finishLifecycleOperation()
    }

    private func waitForPackageMutations() async {
        guard activePackageMutations > 0 else { return }
        await withCheckedContinuation { continuation in
            packageMutationWaiters.append(continuation)
        }
    }

    private func waitForLifecycleOperations() async {
        guard activeLifecycleOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(continuation)
        }
    }

    private func waitForStartupCompletion(
        allowingReservedPackageMutation: Bool = false
    ) async throws(RuntimeHostError) {
        guard hasStarted else {
            throw .notStarted
        }
        if !startupCompleted {
            await withCheckedContinuation { continuation in
                if startupCompleted {
                    continuation.resume()
                } else {
                    startupWaiters.append(continuation)
                }
            }
        }
        guard !isShuttingDown || allowingReservedPackageMutation && activePackageMutations > 0 else {
            throw .shuttingDown
        }
        if hostState == "starting" {
            throw .startupFailed(step: 11, code: "runtime.serviceUnavailable")
        }
    }

    private func completeStartup() {
        guard !startupCompleted else { return }
        startupCompleted = true
        let waiters = startupWaiters
        startupWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForShutdownCompletion() async {
        await withCheckedContinuation { continuation in
            if shutdownCompleted {
                continuation.resume()
            } else {
                shutdownWaiters.append(continuation)
            }
        }
    }

    private func completeShutdown() {
        shutdownCompleted = true
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func recordDegradedStartup(step: Int, code: String) {
        if startupFailure == nil {
            startupFailure = (step, code)
        }
        logger?.error(
            "Daemon startup step \(step, .public) failed",
            errorCode: code
        )
    }

    private func progressHistory() -> [BootRecord] {
        let records = startupAssessment?.record.bootHistory ?? []
        return records.map { record in
            var markers: [String: Double] = [:]
            let markerNames = [
                "kernel": PerfMarker.kernelStart,
                "init": PerfMarker.androidInit,
                "systemServer": PerfMarker.systemServerReady,
                "bootCompleted": PerfMarker.bootCompleted,
                "agentsConnecting": PerfMarker.agentConnected,
                "runtimeReady": PerfMarker.runtimeReady,
            ]
            for (phase, marker) in markerNames {
                if let duration = record.phasesMs[phase] {
                    markers[marker.rawValue] = Double(duration)
                }
            }
            return BootRecord(
                recordedAt: record.recordedAt,
                operationID: UUID(),
                bootKind: record.kind,
                image: record.imageVersion,
                gpuProfile: "unknown",
                memoryGiB: 0,
                cpuCount: 0,
                markers: markers,
                outcome: "ready"
            )
        }
    }

    private func recordSuccessfulBootIfPresent() {
        guard let boot = BootRecordLog.read(from: paths.bootPerformanceFile).last,
            boot.outcome == "ready",
            recordedBootOperationIDs.insert(boot.operationID).inserted
        else {
            return
        }
        let phaseNames = [
            "kernel": PerfMarker.kernelStart,
            "init": PerfMarker.androidInit,
            "systemServer": PerfMarker.systemServerReady,
            "bootCompleted": PerfMarker.bootCompleted,
            "agentsConnecting": PerfMarker.agentConnected,
            "runtimeReady": PerfMarker.runtimeReady,
        ]
        let phasesMs = Dictionary(
            uniqueKeysWithValues: phaseNames.compactMap { phase, marker -> (String, Int)? in
                guard let milliseconds = boot.markers[marker.rawValue],
                    milliseconds.isFinite,
                    milliseconds >= 0
                else {
                    return nil
                }
                return (phase, Int(milliseconds.rounded()))
            }
        )
        if let stateStore {
            do {
                try stateStore.appendBootHistory(
                    DaemonBootHistory(
                        recordedAt: boot.recordedAt,
                        imageVersion: boot.image,
                        kind: boot.bootKind,
                        phasesMs: phasesMs
                    )
                )
                try stateStore.clearFailedBootHistory()
                if let record = try stateStore.current(), let assessment = startupAssessment {
                    startupAssessment = DaemonStartupAssessment(
                        previousExitWasUnclean: assessment.previousExitWasUnclean,
                        crashLoopActive: false,
                        record: record
                    )
                }
            } catch {
                logger?.warning("Could not update daemon boot history", errorCode: String(describing: error))
            }
        }
    }

    private var headlessLaunchHookIsEnabled: Bool {
        #if DEBUG
            buildInfo.configuration == .debug && environment["APKRUN_TEST_HEADLESS_LAUNCH"] == "1"
        #else
            false
        #endif
    }

    private func makeHeadlessSessionService() async throws(RuntimeWireError) -> any RuntimeSessionService {
        if let headlessSessionService {
            return headlessSessionService
        }
        guard let supervisor else {
            throw RuntimeWireError.runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent or app display pool isn't ready.",
                remediation: "Start Android and try again."
            )
        }
        let generation = runtimeSessionGeneration
        guard let guestAgent = await supervisor.developmentGuestAgent,
            runtimeSessionGeneration == generation,
            await supervisor.state == .ready,
            let displayPool = await supervisor.makeDisplayPool(),
            runtimeSessionGeneration == generation,
            await supervisor.state == .ready,
            runtimeSessionGeneration == generation,
            !isShuttingDown
        else {
            throw RuntimeWireError.runtime(
                "guestAgentUnavailable",
                message: "The Android Guest Agent or app display pool isn't ready.",
                remediation: "Start Android and try again."
            )
        }
        if let headlessSessionService {
            return headlessSessionService
        }
        let service = DaemonHeadlessSessionService(
            guestAgent: guestAgent,
            displayPool: displayPool,
            logSink: diagnostics?.logSink,
            onSessionEnded: { [weak self] packageID in
                await self?.releaseSessionActivity(packageID)
            }
        )
        headlessSessionService = service
        return service
    }

    private func packageQueryServiceInstance() -> EmbeddedPackageService {
        if let packageQueryService {
            return packageQueryService
        }
        let service = EmbeddedPackageService(paths: paths)
        packageQueryService = service
        return service
    }

    private func attachPackageQueriesIfRuntimeIsReady(
        to service: EmbeddedPackageService
    ) async throws(RuntimeWireError) {
        guard let supervisor, await supervisor.state == .ready else {
            await service.detachRuntime()
            return
        }
        guard let image, let instanceStore, let diagnostics else {
            throw RuntimeWireError.runtime(
                "serviceUnavailable",
                message: "The Android package service is not ready.",
                remediation: "Restart the APKRun background service and retry."
            )
        }
        let context = DevelopmentRuntimeContext(
            image: image,
            instanceStore: instanceStore,
            supervisor: supervisor,
            diagnostics: diagnostics
        )
        try await service.attachRuntime(
            context: context,
            environment: environment,
            startRuntimeIfNeeded: false,
            recoverPendingTransactions: false,
            refreshInventoryAfterAttach: false
        )
    }

    private static let launchUnavailableError = RuntimeWireError.runtime(
        "windowUnavailable",
        message: "APKRun can't open an Android app window in this build.",
        remediation: "Use a Debug headless launch or update APKRun when native app windows are available."
    )
    private static let guestAgentUnavailableError = RuntimeWireError.runtime(
        "guestAgentUnavailable",
        message: "The Android Guest Agent is unavailable.",
        remediation: "Start Android and try again."
    )

    private static func sessionWireError(for error: RuntimeHostError) -> RuntimeWireError {
        let code: String
        switch error {
        case .notStarted, .alreadyStarted, .crashLoopActive, .stateStore:
            code = "runtime.hostStartupFailed"
        case .startupFailed(_, let startupCode):
            code = startupCode.contains(".") ? startupCode : "runtime.hostStartupFailed"
        case .runtimeFailure(let failure):
            code = failure.qualifiedCode
        case .image(let failure):
            code = failure.qualifiedCode
        case .shuttingDown:
            code = "runtime.hostShuttingDown"
        case .invalidTransition:
            code = "runtime.invalidTransition"
        case .guestAgentBundle:
            code = "runtime.guestAgentBundleMissing"
        case .runtimeBoot(let failure):
            code = failure.qualifiedCode
        }
        let entry = ErrorCatalog.entry(for: code)
        let domain = String(code.split(separator: ".", maxSplits: 1).first ?? "runtime")
        return RuntimeWireError(
            domain: domain,
            code: code,
            message: entry?.parameters.isEmpty == true
                ? entry?.message?["en"] ?? "APKRun couldn't start Android."
                : "APKRun couldn't start Android.",
            remediation: entry?.parameters.isEmpty == true ? entry?.remediation?["en"] : nil
        )
    }

    private func recordLatestFailedBootIfPresent() {
        guard let boot = BootRecordLog.read(from: paths.bootPerformanceFile).last,
            boot.outcome.hasPrefix("failed:"),
            recordedBootOperationIDs.insert(boot.operationID).inserted
        else {
            return
        }
        do {
            try stateStore?.recordFailedBoot(at: boot.recordedAt)
        } catch {
            logger?.error("Could not record a failed Android boot", errorCode: String(describing: error))
        }
    }

    private static func describe(_ state: RuntimeState) -> String {
        switch state {
        case .stopped: "stopped"
        case .booting(let phase): "booting(\(phase.description))"
        case .ready: "ready"
        case .suspended: "suspended"
        case .stopping(_): "stopping"
        case .failed: "failed"
        }
    }
}
