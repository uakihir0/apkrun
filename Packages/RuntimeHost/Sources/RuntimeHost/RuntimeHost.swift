import APKStoreCore
import AppKit
import CoreGraphics
import CryptoKit
import DiagnosticsCore
import Foundation
import ImageCore
import ImageIO
import IntegrationCore
import RuntimeAPI
import RuntimeCore
import UpdateCore
import WrapperCore

typealias WireOperationID = RuntimeAPI.OperationID

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

struct RuntimeTrackedOperation {
    let handle: OperationHandle
    let requestPayload: Data
    var snapshot: OperationSnapshot
    var isCancellable: Bool
    var task: Task<Void, Never>?
}

/// Composes the daemon's per-user runtime and owns it for the process lifetime.
///
/// The host acquires the same instance lock used by `apkrun dev`, records its process state,
/// opens the current image, and creates one RuntimeSupervisor. Runtime start remains on demand.
public actor RuntimeHost {
    nonisolated let eventHub = RuntimeEventHub()

    let paths: APKRunPaths
    private let buildInfo: BuildInfo
    private let environment: [String: String]
    private let executableURL: URL
    private let uncleanExitRecoveryOverride: (any DaemonUncleanExitRecovering)?
    /// When true, Android-bound operations fail with `runtime.notProvisioned` until `setup`
    /// completes (runtime-daemon.md §9.2). The daemon enforces it; dev and test hosts do not.
    private let enforceProvisioning: Bool
    private var provisioningState: WireProvisioningState = .notStarted
    private var imageStore: ImageStore?
    private var diagnostics: DiagnosticsContext?
    /// The health-check registry, for checks hosted outside this file
    /// (`updates.waiting` in RuntimeHostUpdates.swift).
    var healthCheckRegistry: HealthCheckRegistry? {
        diagnostics?.healthChecks
    }
    private var logger: APKLogger?
    private var instanceLock: InstanceLock?
    private var stateStore: DaemonStateStore?
    private var startupAssessment: DaemonStartupAssessment?
    private var image: InstalledImage?
    private var instanceStore: InstanceStore?
    var supervisor: RuntimeSupervisor?
    private var supervisorEventsTask: Task<Void, Never>?
    private var packageQueryService: EmbeddedPackageService?
    private var wrapperRegistry: WrapperRegistry?
    private var wrapperRegistryLoadTask: Task<WrapperRegistry, Never>?
    private var wrapperHealthChecksRegistered = false
    /// Package IDs with a `wrapperCreate` operation in flight.
    private var wrapperCreationsInFlight: Set<String> = []
    /// The wrapper statuses of the last sweep or list pass (wrapper.md §9.1).
    private var latestWrapperStatuses: [String: WrapperStatus] = [:]
    var headlessSessionService: (any RuntimeSessionService)?
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
    var activePackageMutations = 0
    private var runtimeStartTask: Task<Result<Void, RuntimeHostError>, Never>?
    /// Managed-package reinstalls still pending after the last userdata reset (§9.5).
    private var pendingReinstallIDs: Set<RuntimePackageID> = []
    /// The background reinstall reconcile started after a successful boot.
    private var reconcileTask: Task<Void, Never>?
    private var isRuntimeStopping = false
    private var isRuntimeResetting = false
    private var isRuntimeRestarting = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var packageMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    var trackedOperations: [WireOperationID: RuntimeTrackedOperation] = [:]
    /// The lazily created update service (update-system.md). Internal for
    /// `RuntimeHostUpdates.swift`.
    var updateService: EmbeddedUpdateService?
    /// The §3 update scheduler (RuntimeHostUpdates.swift).
    var updateScheduler: UpdateScheduler?
    /// The §7.1 gentle-update gate shared by update installs, created with
    /// the pump tasks below on first use.
    var updateGate: GentleUpdateGate?
    /// §7.2 trigger pumps: runtime events and the 10-minute staged+ready tick.
    var updateGatePumpTask: Task<Void, Never>?
    var updateGateTimerTask: Task<Void, Never>?
    /// §7.1 quiet-period re-evaluation (GU4), rearmed on every drain.
    var updateGateQuietTask: Task<Void, Never>?
    /// Internal subscribers of the single `supervisor.events` consumer for
    /// §7.2 update triggers; `consumeSupervisorState` feeds them so the
    /// update path never races the host's own event loop.
    var updateEventContinuations: [UUID: AsyncStream<UpdateRuntimeEvent>.Continuation] = [:]
    /// The idle controller the `storeOperation` assertion holds (#75 wires
    /// its suspend/stop deadlines).
    let updateIdleController = IdleController()
    /// §3.5: set when `ensureReady(.update)` booted a stopped runtime so
    /// it stops again once the admitted installs finish (update-system.md).
    var updateBootedForInstall = false
    /// `updates.waiting` registers once when the update service is created.
    var updatesHealthChecksRegistered = false
    private var packageActivityReservations = PackageActivityReservations()
    /// The perf record writer (`perf/launches.jsonl`), created with `paths`.
    private var perfRecords: PerfRecordWriter?
    /// When `perfStatistics` was last reset (diagnostics.md §9.3).
    private var statisticsSinceInstant: ContinuousClock.Instant = .now
    private var statisticsSinceDate = Date()
    /// Launches waiting for `FIRST_FRAME_DISPLAYED` or their session's end, by session ID.
    private var pendingLaunchRecords: [UUID: PendingLaunchRecord] = [:]
    /// The §2.3 policy and §4 clipboard coordinator (desktop-integration.md);
    /// internal so the RuntimeHostIntegrations extension can build it lazily.
    var clipboardCoordinator: ClipboardCoordinator?
    /// The guest→coordinator clip relay; alive while the guest agent is.
    var clipboardRelayTask: Task<Void, Never>?
    /// Cached settings and capabilities for the synchronous policy closures.
    let integrationSettings = IntegrationSettingsCache()

    /// The supervisor the integration channel sends through.
    func runtimeSupervisorForIntegrations() -> RuntimeSupervisor? {
        supervisor
    }

    /// The store service that answers per-package `integrations.*` settings.
    func packageServiceForIntegrations() -> EmbeddedPackageService? {
        packageQueryService
    }

    /// The session service that resolves session IDs to packages.
    func sessionServiceForIntegrations() -> DaemonHeadlessSessionService? {
        headlessSessionService as? DaemonHeadlessSessionService
    }

    /// `settings.json` of the data root (configuration.md §1.2).
    var integrationSettingsFile: URL {
        paths.settingsFile
    }

    /// A launch record in progress (diagnostics.md §4.3).
    private struct PendingLaunchRecord {
        /// The record base: `WRAPPER_PROCESS_START`, or request arrival without launchTiming.
        var base: ContinuousClock.Instant
        var packageID: String
        var versionCode: Int64?
        var sessionID: UUID?
        var operationID: String?
        var launchState: String
    }

    /// Creates a daemon host for the current user.
    public init(
        paths: APKRunPaths = APKRunPaths(),
        buildInfo: BuildInfo = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "apkrund"),
        uncleanExitRecovery: (any DaemonUncleanExitRecovering)? = nil,
        enforceProvisioning: Bool = false
    ) {
        self.paths = paths
        self.buildInfo = buildInfo
        self.environment = environment
        self.executableURL = executableURL
        uncleanExitRecoveryOverride = uncleanExitRecovery
        self.enforceProvisioning = enforceProvisioning
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
        recordedBootOperationIDs = Set(
            BootRecordLog.read(from: paths.bootPerformanceFile).map(\.operationID)
        )
        perfRecords = PerfRecordWriter(paths: paths)
        perfRecords?.enforceLimits()

        // Load the wrapper registry and recover pending/refreshing entries at
        // daemon start (wrapper.md §6.2), independent of the first verify call.
        Task { _ = await self.wrapperRegistryInstance() }
        // Quick wrapper sweep at apkrund start + 60 s (wrapper.md §9.1).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.runWrapperSweep()
        }
        // apkrund-start trigger (update-system.md §3.3): arm the scheduler.
        Task { await self.updateSchedulerInstance().start() }

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
            imageStore = images
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

        // Startup step 7: the provisioning record feeds status and the notProvisioned gate.
        if instanceLock != nil, let record = try? await provisioningStore.load() {
            if record.provisioned {
                provisioningState = .complete
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
                        captureLogcat: false
                    ),
                    diagnostics: diagnostics,
                    guestAgentBundle: guestAgent,
                    guestAgentTimeout: .seconds(30)
                )
                supervisor = runtimeSupervisor
                observeSupervisorEvents(from: runtimeSupervisor)
            } catch {
                recordDegradedStartup(step: 8, code: error.qualifiedCode)
            }
        }

        guard !isShuttingDown else {
            completeStartup()
            return
        }
        hostState = startupFailure == nil ? "running" : "degraded"
        logger.notice("Daemon startup completed with host state \(hostState, .public)")
        completeStartup()
    }

    /// Boots Android on demand. An explicit start is allowed after the crash-loop guard activates.
    public func startRuntime(reason: StartReason = .user) async throws(RuntimeHostError) {
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
    }

    private func performRuntimeStart(
        reason: StartReason,
        allowingReservedPackageMutation: Bool
    ) async throws(RuntimeHostError) {
        if let startupFailure {
            throw .startupFailed(step: startupFailure.step, code: startupFailure.code)
        }
        if enforceProvisioning, provisioningState != .complete {
            throw .runtimeFailure(.notProvisioned)
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
            case .automatic:
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
        // Retry managed packages still marked for reinstall in the background (§9.5):
        // a launch waits on this only when its own package is still pending. The set
        // is read here, not in the task, so a launch racing the reconcile start sees it.
        do {
            let service = packageQueryService ?? packageQueryServiceInstance()
            try await service.open()
            pendingReinstallIDs = Set(try await service.pendingReinstalls())
        } catch {
            pendingReinstallIDs = []
        }
        guard !pendingReinstallIDs.isEmpty else { return }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            await self.reconcileManagedReinstalls()
            await self.clearReconcileTask()
        }
    }

    private func clearReconcileTask() {
        reconcileTask = nil
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

    func stopRuntimeBody(reason: StopReason) async throws(RuntimeHostError) {
        try await waitForStartupCompletion()
        try beginLifecycleOperation()
        defer { finishLifecycleOperation() }
        runtimeSessionGeneration &+= 1
        if let service = headlessSessionService as? DaemonHeadlessSessionService {
            await service.shutdown()
        }
        await supervisor?.stop(reason: reason)
        await packageQueryService?.detachRuntime()
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
        try beginPackageLaunch(request.packageID)
        defer { finishPackageLaunch(request.packageID) }
        let launchTracking = await beginLaunchRecord(request)
        do {
            guard headlessLaunchHookIsEnabled else {
                throw Self.launchUnavailableError
            }
            // runtime-daemon.md §7.2: open the window owner first — the registered
            // wrapper when its checks pass, else the generic launcher --package.
            await openWindowOwner(for: request.packageID)
            do {
                try await startRuntime(reason: .automatic)
            } catch {
                throw Self.sessionWireError(for: error)
            }
            // A package still marked needsReinstall must be restored before it can open;
            // an unaffected package's launch never waits on the background reconcile.
            if pendingReinstallIDs.contains(request.packageID), let reconcileTask {
                _ = await reconcileTask.value
            }
            try requirePackageLaunchAllowed(request.packageID)
            let service = try await makeHeadlessSessionService()
            try requirePackageLaunchAllowed(request.packageID)
            let result = try await service.launch(request)
            completeLaunchRecord(launchTracking, sessionID: result.sessionID)
            return result
        } catch {
            failLaunchRecord(
                launchTracking,
                code: (error as? RuntimeWireError)?.code ?? "runtime.internal"
            )
            throw (error as? RuntimeWireError)
                ?? .runtime("internal", message: "APKRun's background service failed.")
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
            return try await headlessSessionService.terminate(request)
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

    /// Drops an import ticket and its private APK copies without starting Android.
    public func discardImport(
        _ request: RuntimeDiscardImportRequest
    ) async throws(RuntimeWireError) {
        let service = packageQueryServiceInstance()
        try await service.open()
        try await service.discardImport(request)
    }

    /// Adopts a package Android has but APKRun does not manage (package-store.md §9.3).
    public func adoptPackage(
        _ request: RuntimeAdoptPackageRequest
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        let service = packageQueryServiceInstance()
        try await service.open()
        // Adoption queries Android live; attach the store-agent channel like every
        // other package op so a freshly booted runtime is usable right away.
        try await attachPackageQueriesIfRuntimeIsReady(to: service)
        return try await service.adoptPackage(request)
    }

    /// Starts Android on demand, attaches its package channel, and installs an inspected import.
    public func installImported(
        _ request: RuntimeInstallImportedRequest
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        let packageID = try await resolvePackageIDForInstall(request)
        try reservePackageInstall(packageID)
        do {
            try beginPackageMutation()
        } catch {
            packageActivityReservations.finishInstall(packageID: packageID.rawValue)
            throw Self.sessionWireError(for: error)
        }
        defer {
            packageActivityReservations.finishInstall(packageID: packageID.rawValue)
            finishPackageMutation()
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
        do {
            try beginPackageMutation()
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
    ) throws(RuntimeWireError) -> OperationHandle {
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
        do {
            try beginPackageMutation()
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

    /// Starts a package repair asynchronously (package-store.md §11.1): a
    /// `broken` package is reinstalled from its retained `current/` artifacts.
    func beginRepairPackage(
        _ request: RuntimePackageRequest,
        operationID requestedID: WireOperationID,
        clientKind: RuntimeClientKind
    ) throws(RuntimeWireError) -> OperationHandle {
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
            guard existing.handle.kind == .repair, existing.requestPayload == requestPayload else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request."
                )
            }
            return existing.handle
        }

        do {
            try packageActivityReservations.beginInstall(packageID: request.packageID.rawValue)
        } catch {
            throw Self.packageOperationInProgressError
        }
        do {
            try beginPackageMutation()
        } catch {
            packageActivityReservations.finishInstall(packageID: request.packageID.rawValue)
            throw Self.sessionWireError(for: error)
        }

        let handle = OperationHandle(operationID: requestedID, kind: .repair)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .repair,
            packageID: request.packageID,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(
                stage: "startingRuntime",
                message: "Starting Android…"
            )
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
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
                    await self.runRepairPackageOperation(
                        request,
                        operationID: requestedID,
                        clientKind: clientKind
                    )
                }
            } else {
                await self.runRepairPackageOperation(
                    request, operationID: requestedID, clientKind: clientKind)
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
        defer {
            packageActivityReservations.finishInstall(packageID: packageID.rawValue)
            finishPackageMutation()
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
        defer {
            if request.options.forget {
                packageActivityReservations.finishForget(packageID: request.packageID.rawValue)
            } else {
                packageActivityReservations.finishUninstall(packageID: request.packageID.rawValue)
            }
            finishPackageMutation()
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

    private func runRepairPackageOperation(
        _ request: RuntimePackageRequest,
        operationID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async {
        defer {
            packageActivityReservations.finishInstall(packageID: request.packageID.rawValue)
            finishPackageMutation()
        }
        do {
            let service = packageQueryServiceInstance()
            do {
                try await service.open()
            } catch {
                throw Self.operationWireError(for: error)
            }
            try await startRuntimeForPackageMutation(reason: clientKind == .cli ? .cli : .user)
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
            guard !Task.isCancelled else {
                throw Self.cancelledOperationError
            }
            try await enterPackageStoreMutation(
                operationID: operationID,
                stage: "repairing",
                message: "Reinstalling the Android package…"
            )
            let change = try await service.repairPackage(request)
            let summary: RuntimePackageSummary
            switch change {
            case .installed(let installed), .updated(let installed, _):
                summary = installed
            default:
                throw Self.operationWireError(for: CancellationError())
            }
            eventHub.publishPackageChange(change, operationID: operationID)
            finishOperation(operationID, result: .succeeded(.package(summary)))
            logger?.notice(
                "Package repair operation completed for \(request.packageID.rawValue, .public)"
            )
        } catch {
            if Task.isCancelled {
                finishOperation(operationID, result: .cancelled)
                logger?.notice("Package repair operation was cancelled")
                return
            }
            let wireError = Self.operationWireError(for: error)
            finishOperation(operationID, result: .failed(wireError))
            logger?.error("Package repair operation failed", errorCode: wireError.code)
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
        // §8: the Mac app goes to the Trash unless the caller asked to keep
        // it (`--keep-wrapper`); a missing wrapper is fine.
        if request.options.trashWrappers {
            do {
                _ = try await removeWrapper(packageID: request.packageID, trash: true)
            } catch {
                logger?.info(
                    "Uninstall had no wrapper to trash for \(request.packageID.rawValue, .public)")
            }
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
    ) throws(RuntimeWireError) {
        guard !Task.isCancelled else {
            throw Self.cancelledOperationError
        }
        if let operationID {
            // PackageStore reconciles ambiguous guest results and journals the transaction to a
            // terminal state once its Store Agent operation begins.
            setPackageMutationNotCancellable(operationID, stage: stage, message: message)
        }
    }

    func finishOperation(_ operationID: WireOperationID, result: RuntimeAPI.OperationResult) {
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

    /// Snapshots of the live app sessions (host-ui.md §5.2).
    public func listSessions() async -> [WireSessionSummary] {
        guard let service = sessionServiceForIntegrations() else {
            return []
        }
        return await service.sessionSnapshots().compactMap(Self.wireSessionSummary)
    }

    /// The composed Mac icon PNG of one package (host-ui.md §5.3).
    ///
    /// Returns `nil` when the store holds no rendered icon; callers fall back
    /// to the host preview placeholder.
    public func packageIcon(packageID: RuntimePackageID) async -> Data? {
        let service = packageQueryServiceInstance()
        try? await service.open()
        guard
            let rendered = await service.renderedIconLayers(for: packageID),
            let master = Self.composedIconMaster(
                kind: rendered.manifest.kind, layers: rendered.layers),
            let png = try? IconComposer.pngData(master)
        else { return nil }
        return png
    }

    /// Maps a session snapshot to its wire summary (host-ui.md §5.2).
    static func wireSessionSummary(_ snapshot: AppSessionSnapshot) -> WireSessionSummary? {
        let phase: WireSessionPhase
        switch snapshot.state {
        case .requested, .waitingForRuntime, .acquiringDisplay, .launching:
            phase = .starting
        case .running:
            phase = .running
        case .backgrounded:
            phase = .backgrounded
        case .closing:
            phase = .closing
        case .ended:
            phase = .closing
        }
        guard case .app(let sessionID) = snapshot.id,
            let packageID = RuntimePackageID(rawValue: snapshot.packageID)
        else { return nil }
        return WireSessionSummary(
            sessionID: sessionID,
            packageID: packageID,
            phase: phase
        )
    }

    /// The `sessions` topic event for one committed session snapshot.
    static func sessionChange(for snapshot: AppSessionSnapshot) -> SessionChange? {
        guard let summary = wireSessionSummary(snapshot) else {
            return nil
        }
        if case .ended(let reason) = snapshot.state {
            return .ended(
                sessionID: summary.sessionID,
                packageID: summary.packageID,
                reason: sessionEndReasonName(reason))
        }
        return .changed(summary)
    }

    /// The `SessionEndReason` case name sent on the wire.
    static func sessionEndReasonName(_ reason: SessionEndReason) -> String {
        switch reason {
        case .userClosed: return "userClosed"
        case .appExited: return "appExited"
        case .appCrashed: return "appCrashed"
        case .runtimeStopped: return "runtimeStopped"
        case .updating: return "updating"
        case .runtimeUpdating: return "runtimeUpdating"
        case .packageUninstalled: return "packageUninstalled"
        case .updateHealthCheck: return "updateHealthCheck"
        case .error: return "error"
        }
    }

    /// Verifies a wrapper bundle against the registry and the package store (runtime-api.md §10.4).
    ///
    /// The check never starts Android and never reads the store beyond one package list. When the
    /// store is unreadable the package-presence check is skipped rather than reported wrong.
    public func verifyWrapper(
        _ request: VerifyWrapperRequest
    ) async throws(RuntimeWireError) -> WrapperVerification {
        let registry = await wrapperRegistryInstance()
        let service = packageQueryServiceInstance()
        let knownPackages: Set<String>?
        do {
            try await service.open()
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
            let list = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            knownPackages = Set(list.packages.map(\.packageID.rawValue))
        } catch {
            knownPackages = nil
        }
        let validator = WrapperValidator(
            registry: registry,
            currentLauncher: launcherBuild(),
            packageExists: { knownPackages?.contains($0) ?? true },
            iconDigest: { packageID in
                // §8.5: the digest of the icon master the store would
                // produce today, or nil when the store has none.
                guard let runtimeID = RuntimePackageID(rawValue: packageID) else {
                    return nil
                }
                guard
                    let rendered = await service.renderedIconLayers(for: runtimeID),
                    let composed = RuntimeHost.composedIcon(
                        kind: rendered.manifest.kind, layers: rendered.layers)
                else { return nil }
                return composed.digest
            },
            sink: diagnostics?.logSink
        )
        do {
            let verification = try await validator.verify(
                url: request.bundleURL, deep: request.deep)
            // The §9.1 hash list travels only with `deep`; it is the wrapper
            // the update must leave unchanged (#50).
            let fileHashes: [WrapperFileHashWire]? =
                if request.deep {
                    try? WrapperFileHashes.compute(bundleURL: request.bundleURL)
                        .map { WrapperFileHashWire(path: $0.path, sha256: $0.sha256) }
                } else {
                    nil
                }
            return WrapperVerification(
                bundleURL: verification.bundleURL,
                bundleID: verification.bundleID,
                packageID: verification.packageID,
                kind: verification.kind.map {
                    WrapperKindTag(rawValue: $0.rawValue) ?? .local
                },
                registered: verification.registered,
                state: verification.state,
                problems: verification.problems,
                signer: verification.signer.map { $0 == "adHoc" ? .adHoc : .unknown },
                cdhash: verification.cdhash,
                launcherVersion: verification.launcherVersion,
                launcherAPI: verification.launcherAPI.flatMap(Self.launcherAPIVersion(_:)),
                bundledVersion: nil,
                fileHashes: fileHashes
            )
        } catch {
            throw Self.wrapperWireError(for: error)
        }
    }

    /// Starts a `wrapperCreate` operation for an installed package
    /// (runtime-api.md §10.3). Portable wrappers and `importTicket` are #90;
    /// `updateDefaults` is only valid with an import ticket.
    func createWrapper(
        _ request: WrapperRequest,
        icon: FileHandle?,
        operationID requestedID: WireOperationID,
        clientKind: RuntimeClientKind
    ) throws(RuntimeWireError) -> OperationHandle {
        guard !request.portable, request.importTicket == nil else {
            throw .runtime(
                "malformedRequest",
                message: "Portable wrappers are not supported yet."
            )
        }
        guard request.updateDefaults == nil else {
            throw .runtime(
                "malformedRequest",
                message: "updateDefaults is only valid with an import ticket."
            )
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
            guard existing.handle.kind == .wrapperCreate, existing.requestPayload == requestPayload
            else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request."
                )
            }
            return existing.handle
        }
        // One generation per package at a time: two writers would interleave
        // the placement and the registry update.
        guard wrapperCreationsInFlight.insert(request.packageID.rawValue).inserted else {
            throw Self.packageOperationInProgressError
        }
        do {
            try beginLifecycleOperation()
        } catch {
            wrapperCreationsInFlight.remove(request.packageID.rawValue)
            throw Self.sessionWireError(for: error)
        }

        let handle = OperationHandle(operationID: requestedID, kind: .wrapperCreate)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .wrapperCreate,
            packageID: request.packageID,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(
                stage: "generating",
                message: "Generating the Mac app…"
            )
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            snapshot: snapshot,
            isCancellable: false,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: requestedID)
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            if let diagnosticsID = DiagnosticsCore.OperationID(wire: requestedID.wireValue) {
                let context = OperationContext(operationID: diagnosticsID)
                await OperationContext.$current.withValue(context) {
                    await self.runCreateWrapperOperation(
                        request,
                        icon: icon,
                        operationID: requestedID
                    )
                }
            } else {
                await self.runCreateWrapperOperation(request, icon: icon, operationID: requestedID)
            }
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    /// Runs a `wrapperCreate` operation to its terminal state.
    private func runCreateWrapperOperation(
        _ request: WrapperRequest,
        icon: FileHandle?,
        operationID: WireOperationID
    ) async {
        defer {
            wrapperCreationsInFlight.remove(request.packageID.rawValue)
            finishLifecycleOperation()
        }
        do {
            let info = try await performCreateWrapper(request, icon: icon, operationID: operationID)
            finishOperation(operationID, result: .succeeded(.wrapper(info)))
            logger?.notice(
                "Wrapper creation completed for \(request.packageID.rawValue, .public)")
        } catch {
            if Task.isCancelled {
                finishOperation(operationID, result: .cancelled)
                return
            }
            let wireError = Self.operationWireError(for: error)
            finishOperation(operationID, result: .failed(wireError))
            logger?.error("Wrapper creation failed", errorCode: wireError.code)
        }
    }

    /// Generates the wrapper bundle for a `wrapperCreate` operation.
    private func performCreateWrapper(
        _ request: WrapperRequest,
        icon: FileHandle?,
        operationID: WireOperationID
    ) async throws(RuntimeWireError) -> WrapperInfo {
        guard let launcher = launcherBuild() else {
            throw Self.wrapperWireError(for: .launcherTemplateInvalid("missing"))
        }
        let registry = await wrapperRegistryInstance()

        // The package record supplies the display name, the update authority,
        // and (with #56) the Android icon.
        let service = packageQueryServiceInstance()
        try await service.open()
        try await attachPackageQueriesIfRuntimeIsReady(to: service)
        let details: RuntimePackageDetails
        do {
            details = try await service.packageInfo(
                RuntimePackageRequest(packageID: request.packageID))
        } catch {
            guard error.code == "store.packageNotFound" else { throw error }
            throw Self.wrapperWireError(for: .packageNotInstalled(request.packageID))
        }
        guard details.summary.managed, details.summary.state == .installed else {
            throw Self.wrapperWireError(for: .packageNotInstalled(request.packageID))
        }

        var iconDigest: String?
        var customIconPNG: Data?
        let iconSource: WrapperIconSource
        switch request.icon {
        case .custom:
            let data = icon.flatMap { try? $0.readToEnd() }
            guard let data, !data.isEmpty else {
                throw Self.wrapperWireError(for: .customIconInvalid(.unreadable))
            }
            // A custom icon is validated, composed, and never tracked by
            // iconDigest (wrapper.md §8.2 `custom`, §8.5). Its PNG master is
            // kept so `Wrappers/icons/<bundleId>.png` can reuse it (§4.2).
            let customURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("apkrun-custom-icon-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: customURL) }
            do {
                try data.write(to: customURL)
                iconSource = .rendered(try IconComposer.customIconData(at: customURL))
                customIconPNG = try? IconComposer.customIconPNG(at: customURL)
            } catch let failure as WrapperFailure {
                throw Self.wrapperWireError(for: failure)
            } catch {
                throw Self.wrapperWireError(for: .customIconInvalid(.unreadable))
            }
        case .android, .none:
            // Store-rendered layers compose the icon; otherwise the
            // placeholder (wrapper.md §8.2; issue #56 step 3).
            if let rendered = await service.renderedIconLayers(for: request.packageID),
                let composed = Self.composedIcon(
                    kind: rendered.manifest.kind, layers: rendered.layers)
            {
                iconSource = .rendered(composed.icns)
                iconDigest = composed.digest
            } else {
                iconSource = .placeholder
            }
        }

        var window = WindowDefaults()
        if let windowDefaults = request.windowDefaults {
            window.defaultWidth = windowDefaults.defaultWidth ?? window.defaultWidth
            window.defaultHeight = windowDefaults.defaultHeight ?? window.defaultHeight
            window.resizable = windowDefaults.resizable ?? window.resizable
        }
        let updates = WrapperUpdateDefaults(
            authority: details.summary.updateAuthority == .apkrun ? .apkrun : .manual,
            mode: .automatic,
            provider: nil
        )
        let configuration = WrapperConfiguration(
            packageID: request.packageID,
            displayName: request.displayName ?? details.summary.displayName,
            icon: iconSource,
            window: window,
            updates: updates,
            kind: .local
        )
        let destination: WrapperDestination
        switch request.destination {
        case .userApplications, .none:
            destination = .userApplications
        case .applications:
            destination = .applications
        case .directory(let url):
            destination = .directory(url)
        }
        let replace: ReplacePolicy = request.replace == .sameWrapper ? .sameWrapper : .never
        let generator = AppWrapperGenerator(
            environment: AppWrapperGenerator.Environment(
                launcher: launcher,
                registry: registry,
                installer: WrapperInstaller(sink: diagnostics?.logSink),
                stagingRoot: paths.wrapperStagingDirectory
            )
        )
        let generation = WrapperGenerationRequest(
            configuration: configuration,
            destination: destination,
            fileName: request.fileName,
            replace: replace
        )
        let generated: GeneratedWrapper
        do {
            generated = try await generator.generate(generation)
        } catch {
            throw Self.wrapperWireError(for: error)
        }

        if iconDigest != nil {
            try? await registry.setIconDigest(bundleID: generated.bundleID, digest: iconDigest)
        }
        if let customIconPNG {
            let iconFile = "\(generated.bundleID).png"
            let iconURL = paths.wrapperIconsDirectory.appendingPathComponent(iconFile)
            do {
                try FileManager.default.createDirectory(
                    at: paths.wrapperIconsDirectory, withIntermediateDirectories: true)
                try customIconPNG.write(to: iconURL)
                try await registry.setCustomIconFile(
                    bundleID: generated.bundleID, fileName: iconFile)
            } catch {
                // The icon is already in the bundle; only refresh bookkeeping
                // is lost when the source copy cannot be stored.
            }
        }
        guard let entry = await registry.entry(bundleID: generated.bundleID) else {
            throw .runtime("internal", message: "APKRun couldn't register the Mac app.")
        }
        let summary = Self.wrapperSummary(for: entry, packageID: request.packageID)
        eventHub.publishWrapperChange(.created(summary), operationID: operationID)
        return Self.wrapperInfo(for: entry, packageID: request.packageID)
    }

    /// Starts a `wrapperRefresh` operation (wrapper.md §9.3).
    func refreshWrapper(
        packageID: RuntimePackageID,
        change: WrapperRefreshWire,
        icon: FileHandle?,
        operationID requestedID: WireOperationID,
        clientKind: RuntimeClientKind
    ) throws(RuntimeWireError) -> OperationHandle {
        guard !change.makeLocal else {
            throw .runtime(
                "malformedRequest",
                message: "makeLocal is not supported yet.")
        }
        let request = RuntimeRefreshWrapperControlRequest(
            header: APIRequestHeader(
                operationID: requestedID.rawValue, clientKind: clientKind),
            packageID: packageID,
            change: change
        )
        let requestPayload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            requestPayload = try encoder.encode(request)
        } catch {
            throw .runtime(
                "malformedRequest",
                message: "APKRun's background service couldn't read the request.")
        }
        if let existing = trackedOperations[requestedID] {
            guard existing.handle.kind == .wrapperRefresh, existing.requestPayload == requestPayload
            else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request.")
            }
            return existing.handle
        }
        guard wrapperCreationsInFlight.insert(packageID.rawValue).inserted else {
            throw Self.packageOperationInProgressError
        }
        do {
            try beginLifecycleOperation()
        } catch {
            wrapperCreationsInFlight.remove(packageID.rawValue)
            throw Self.sessionWireError(for: error)
        }
        let handle = OperationHandle(operationID: requestedID, kind: .wrapperRefresh)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .wrapperRefresh,
            packageID: packageID,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(stage: "refreshing", message: "Updating the Mac app…")
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            snapshot: snapshot,
            isCancellable: false,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: requestedID)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshWrapperOperation(
                packageID: packageID, change: change, icon: icon, operationID: requestedID)
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    /// Runs a `wrapperRefresh` operation to its terminal state.
    private func runRefreshWrapperOperation(
        packageID: RuntimePackageID,
        change: WrapperRefreshWire,
        icon: FileHandle?,
        operationID: WireOperationID
    ) async {
        defer {
            wrapperCreationsInFlight.remove(packageID.rawValue)
            finishLifecycleOperation()
        }
        do {
            let info = try await performRefreshWrapper(
                packageID: packageID, change: change, icon: icon, operationID: operationID)
            finishOperation(operationID, result: .succeeded(.wrapper(info)))
            logger?.notice("Wrapper refresh completed for \(packageID.rawValue, .public)")
        } catch {
            if Task.isCancelled {
                finishOperation(operationID, result: .cancelled)
                return
            }
            let wireError = Self.operationWireError(for: error)
            finishOperation(operationID, result: .failed(wireError))
            logger?.error("Wrapper refresh failed", errorCode: wireError.code)
        }
    }

    /// Regenerates the wrapper of one package (wrapper.md §9.3 steps 1–8).
    private func performRefreshWrapper(
        packageID: RuntimePackageID,
        change: WrapperRefreshWire,
        icon: FileHandle?,
        operationID: WireOperationID
    ) async throws(RuntimeWireError) -> WrapperInfo {
        guard let launcher = launcherBuild() else {
            throw Self.wrapperWireError(for: .launcherTemplateInvalid("missing"))
        }
        let registry = await wrapperRegistryInstance()
        guard let entry = await registry.entry(packageID: packageID) else {
            throw Self.wrapperWireError(for: .wrapperNotFound(packageID))
        }
        // 1. the wrapper must not be running.
        let runningApps =
            NSRunningApplication
            .runningApplications(withBundleIdentifier: entry.bundleId)
            .filter { !$0.isTerminated }
        if !runningApps.isEmpty {
            guard change.closeRunningApp else {
                throw Self.wrapperWireError(for: .wrapperRunning(entry.displayName))
            }
            for app in runningApps {
                app.terminate()
            }
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let stillRunning =
                    NSRunningApplication
                    .runningApplications(withBundleIdentifier: entry.bundleId)
                    .contains { !$0.isTerminated }
                if !stillRunning {
                    break
                }
            }
            if NSRunningApplication
                .runningApplications(withBundleIdentifier: entry.bundleId)
                .contains(where: { !$0.isTerminated })
            {
                throw Self.wrapperWireError(for: .wrapperRunning(entry.displayName))
            }
        }

        // 2. the entry must be valid or have refresh reasons.
        let (bundleURL, _) = await resolvedWrapperURL(entry: entry, registry: registry)
        let service = packageQueryServiceInstance()
        try await service.open()
        try await attachPackageQueriesIfRuntimeIsReady(to: service)
        var knownPackages: Set<String>?
        if let list = try? await service.listPackages(
            RuntimeListPackagesRequest(filter: .all))
        {
            knownPackages = Set(list.packages.map(\.packageID.rawValue))
        }
        let validator = wrapperValidator(
            registry: registry, service: service, knownPackages: knownPackages)
        let verification: WrapperValidator.Verification
        do {
            verification = try await validator.verify(url: bundleURL, deep: false)
        } catch {
            throw Self.wrapperWireError(
                for: .verificationFailed("the wrapper could not be read"))
        }
        switch verification.state {
        case .valid:
            break
        case .missing, .inaccessible:
            // Missing regenerates through createWrapper (wrapper.md §9.3 step 2).
            throw Self.wrapperWireError(for: .wrapperNotFound(packageID))
        default:
            guard !verification.refreshReasons.isEmpty else {
                throw Self.wrapperWireError(
                    for: .verificationFailed("the wrapper is not updatable"))
            }
        }

        let displayNameOverride: String?
        if let displayName = change.displayName {
            displayNameOverride = displayName.isEmpty ? nil : displayName
        } else {
            displayNameOverride = entry.customization.displayName
        }
        let details = try? await service.packageInfo(
            RuntimePackageRequest(packageID: packageID))
        let displayName =
            displayNameOverride ?? details?.summary.displayName ?? entry.displayName

        // Icons (wrapper.md §8.2): a new custom icon wins; otherwise the
        // recorded custom icon file, the stored Android icon, or the
        // placeholder — `launcherOnly` keeps whatever the entry records.
        var iconDigest: String? = nil
        var customIconPNG: Data? = nil
        var iconSource: WrapperIconSource = .placeholder
        if change.icon {
            let data = icon.flatMap { try? $0.readToEnd() }
            guard let data, !data.isEmpty else {
                throw Self.wrapperWireError(for: .customIconInvalid(.unreadable))
            }
            let customURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("apkrun-custom-icon-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: customURL) }
            do {
                try data.write(to: customURL)
                iconSource = .rendered(try IconComposer.customIconData(at: customURL))
                customIconPNG = try? IconComposer.customIconPNG(at: customURL)
            } catch let failure as WrapperFailure {
                throw Self.wrapperWireError(for: failure)
            } catch {
                throw Self.wrapperWireError(for: .customIconInvalid(.unreadable))
            }
        } else if change.androidIcon {
            if let rendered = await service.renderedIconLayers(for: packageID),
                let composed = Self.composedIcon(
                    kind: rendered.manifest.kind, layers: rendered.layers)
            {
                iconSource = .rendered(composed.icns)
                iconDigest = composed.digest
            }
            try? await registry.setCustomIconFile(bundleID: entry.bundleId, fileName: nil)
        } else if let iconFile = entry.customization.iconFile {
            iconSource = .custom(
                paths.wrapperIconsDirectory.appendingPathComponent(iconFile))
        } else if let rendered = await service.renderedIconLayers(for: packageID),
            let composed = Self.composedIcon(
                kind: rendered.manifest.kind, layers: rendered.layers)
        {
            iconSource = .rendered(composed.icns)
            iconDigest = composed.digest
        }

        // wrapper.json carries the previous defaults.
        var window = WindowDefaults()
        var updates = WrapperUpdateDefaults(
            authority: .manual, mode: .automatic, provider: nil)
        var integrations = IntegrationDefaults()
        if let document = try? JSONDecoder().decode(
            WrapperDocument.self,
            from: (try? Data(
                contentsOf: bundleURL.appendingPathComponent(
                    "Contents/Resources/wrapper.json"))) ?? Data())
        {
            if let docWindow = document.window {
                window.defaultWidth = docWindow.defaultWidth ?? window.defaultWidth
                window.defaultHeight = docWindow.defaultHeight ?? window.defaultHeight
                window.resizable = docWindow.resizable ?? window.resizable
            }
            if let docUpdates = document.updates {
                updates = WrapperUpdateDefaults(
                    authority: docUpdates.authority == .apkrun ? .apkrun : .manual,
                    mode: docUpdates.mode ?? .automatic,
                    provider: docUpdates.provider
                )
            }
            // Integration defaults regenerate unchanged: wrapper.json holds
            // the same fields the configuration produces.
            integrations = IntegrationDefaults()
        }

        // 3. build and sign the new bundle inside the parent folder so the
        //    swap stays on one volume.
        let fileName =
            displayNameOverride.map {
                WrapperFileName.sanitize(displayName: $0, packageID: packageID.rawValue)
            } ?? entry.fileName
        let stagingDirectory = bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".apkrun-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            throw Self.wrapperWireError(for: .destinationNotWritable(bundleURL))
        }
        let generator = AppWrapperGenerator(
            environment: AppWrapperGenerator.Environment(
                launcher: launcher,
                registry: registry,
                installer: WrapperInstaller(sink: diagnostics?.logSink),
                stagingRoot: paths.wrapperStagingDirectory
            )
        )
        let staged: (bundle: URL, cdhash: String)
        do {
            staged = try await generator.stageForRefresh(
                WrapperGenerationRequest(
                    configuration: WrapperConfiguration(
                        packageID: packageID,
                        displayName: displayName,
                        icon: iconSource,
                        window: window,
                        updates: updates,
                        integrations: integrations,
                        kind: entry.kind
                    ),
                    fileName: fileName
                ),
                stagingDirectory: stagingDirectory,
                fileName: fileName
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw Self.wrapperWireError(for: error)
        }

        // 4. registry: refreshing + pendingCdhash.
        do {
            try await registry.beginRefresh(
                bundleID: entry.bundleId,
                stagingPath: stagingDirectory.path,
                pendingCdhash: staged.cdhash
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw Self.wrapperWireError(for: .registryUnavailable)
        }

        // 5. the atomic Contents swap; an App Management denial stages the
        //    new Contents for APKRun.app and reports refreshBlocked (R-20).
        //
        //    A new display name renames the bundle after the swap (§6.4).
        //    The destination is checked before mutating the installed bundle
        //    so a conflict cannot strand the registry with a stale cdhash.
        let newContents = staged.bundle.appendingPathComponent("Contents")
        let liveContents = bundleURL.appendingPathComponent("Contents")
        let renamed = bundleURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileName).app", isDirectory: true)
        let wantsRename =
            displayNameOverride != nil
            && bundleURL.deletingPathExtension().lastPathComponent != fileName
            && renamed != bundleURL
        if wantsRename, FileManager.default.fileExists(atPath: renamed.path) {
            try? FileManager.default.removeItem(at: stagingDirectory)
            try? await abortRefresh(bundleID: entry.bundleId, registry: registry)
            let kind =
                WrapperInstaller(sink: diagnostics?.logSink)
                .classifyConflict(at: renamed, packageID: packageID)
                ?? .otherApp
            throw Self.wrapperWireError(for: .nameConflict(renamed, existing: kind))
        }
        if renamex_np(newContents.path, liveContents.path, UInt32(RENAME_SWAP)) != 0 {
            let token = UUID().uuidString
            let fallback = paths.wrapperStagingDirectory
                .appendingPathComponent(token, isDirectory: true)
            try? FileManager.default.createDirectory(
                at: fallback, withIntermediateDirectories: true)
            try? FileManager.default.moveItem(
                at: staged.bundle,
                to: fallback.appendingPathComponent(
                    "\(fileName).app", isDirectory: true))
            try? FileManager.default.removeItem(at: stagingDirectory)
            try? await abortRefresh(bundleID: entry.bundleId, registry: registry)
            throw Self.wrapperWireError(
                for: .refreshBlocked(bundleURL.path, stagingToken: token))
        }

        // 6. a new display name renames the bundle (conflict rules of §6.4).
        //    A destination that appeared after step 5, or a failed rename,
        //    puts the swapped contents back first so the registry cdhash
        //    still matches the installed bundle.
        var finalURL = bundleURL
        if wantsRename {
            if FileManager.default.fileExists(atPath: renamed.path) {
                await undoContentsSwap(
                    newContents: newContents, liveContents: liveContents,
                    stagingDirectory: stagingDirectory, finalURL: bundleURL,
                    bundleID: entry.bundleId, registry: registry)
                let kind =
                    WrapperInstaller(sink: diagnostics?.logSink)
                    .classifyConflict(at: renamed, packageID: packageID)
                    ?? .otherApp
                throw Self.wrapperWireError(for: .nameConflict(renamed, existing: kind))
            }
            do {
                try FileManager.default.moveItem(at: bundleURL, to: renamed)
                finalURL = renamed
            } catch {
                await undoContentsSwap(
                    newContents: newContents, liveContents: liveContents,
                    stagingDirectory: stagingDirectory, finalURL: bundleURL,
                    bundleID: entry.bundleId, registry: registry)
                throw .runtime(
                    "internalError",
                    message: "APKRun couldn't rename the Mac app.")
            }
        }

        // 7. registry: cdhash = pendingCdhash, active, refreshedAt, bookmark.
        let bookmark = (try? finalURL.bookmarkData()) ?? Data()
        do {
            try await registry.finishRefresh(
                bundleID: entry.bundleId, path: finalURL, bookmark: bookmark)
        } catch {
            throw Self.wrapperWireError(for: .registryUnavailable)
        }
        if let iconDigest {
            try? await registry.setIconDigest(bundleID: entry.bundleId, digest: iconDigest)
        } else if entry.customization.iconFile == nil {
            try? await registry.setIconDigest(bundleID: entry.bundleId, digest: nil)
        }
        if let customIconPNG {
            let iconFile = "\(entry.bundleId).png"
            let iconURL = paths.wrapperIconsDirectory.appendingPathComponent(iconFile)
            do {
                try FileManager.default.createDirectory(
                    at: paths.wrapperIconsDirectory, withIntermediateDirectories: true)
                try customIconPNG.write(to: iconURL)
                try await registry.setCustomIconFile(
                    bundleID: entry.bundleId, fileName: iconFile)
            } catch {
            }
        }

        // 8. delete the old Contents and the staging dir; register the bundle.
        try? FileManager.default.removeItem(at: stagingDirectory)
        _ = WrapperInstaller(sink: diagnostics?.logSink).registerPlaced(at: finalURL)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: finalURL.path)

        guard let refreshed = await registry.entry(bundleID: entry.bundleId) else {
            throw .runtime("internal", message: "APKRun couldn't register the Mac app.")
        }
        let summary = Self.wrapperSummary(for: refreshed, packageID: packageID)
        eventHub.publishWrapperChange(.refreshed(summary), operationID: operationID)
        return Self.wrapperInfo(for: refreshed, packageID: packageID)
    }

    /// Returns a `refreshing` entry to `active` after a failed refresh.
    private func abortRefresh(bundleID: String, registry: WrapperRegistry) async {
        try? await registry.abortRefresh(bundleID: bundleID)
    }

    /// Restores a bundle's pre-swap contents after a post-swap step failed
    /// (wrapper.md §9.3). When the restore swap itself fails, the refresh is
    /// finished against the already-installed new contents instead of being
    /// aborted, so cdhash and bundle never disagree.
    private func undoContentsSwap(
        newContents: URL,
        liveContents: URL,
        stagingDirectory: URL,
        finalURL: URL,
        bundleID: String,
        registry: WrapperRegistry
    ) async {
        if renamex_np(newContents.path, liveContents.path, UInt32(RENAME_SWAP)) == 0 {
            try? FileManager.default.removeItem(at: stagingDirectory)
            await abortRefresh(bundleID: bundleID, registry: registry)
        } else {
            let bookmark = (try? finalURL.bookmarkData()) ?? Data()
            try? await registry.finishRefresh(
                bundleID: bundleID, path: finalURL, bookmark: bookmark)
        }
    }

    /// Starts a `wrapperRefreshAll` operation (wrapper.md §9.4).
    func refreshAllWrappers(
        scope: RefreshAllScope,
        launcherOnly: Bool,
        operationID requestedID: WireOperationID,
        clientKind: RuntimeClientKind
    ) throws(RuntimeWireError) -> OperationHandle {
        let request = RuntimeRefreshAllWrappersControlRequest(
            header: APIRequestHeader(
                operationID: requestedID.rawValue, clientKind: clientKind),
            scope: scope,
            launcherOnly: launcherOnly
        )
        let requestPayload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            requestPayload = try encoder.encode(request)
        } catch {
            throw .runtime(
                "malformedRequest",
                message: "APKRun's background service couldn't read the request.")
        }
        if let existing = trackedOperations[requestedID] {
            guard existing.handle.kind == .wrapperRefreshAll,
                existing.requestPayload == requestPayload
            else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request.")
            }
            return existing.handle
        }
        do {
            try beginLifecycleOperation()
        } catch {
            throw Self.sessionWireError(for: error)
        }
        let handle = OperationHandle(operationID: requestedID, kind: .wrapperRefreshAll)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .wrapperRefreshAll,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(stage: "refreshing", message: "Updating Mac apps…")
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            snapshot: snapshot,
            isCancellable: false,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: requestedID)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshAllWrappersOperation(
                scope: scope, launcherOnly: launcherOnly, operationID: requestedID)
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    /// Runs a `wrapperRefreshAll` operation to its terminal state.
    private func runRefreshAllWrappersOperation(
        scope: RefreshAllScope,
        launcherOnly: Bool,
        operationID: WireOperationID
    ) async {
        defer { finishLifecycleOperation() }
        do {
            let result = try await performRefreshAllWrappers(
                scope: scope, launcherOnly: launcherOnly, operationID: operationID)
            finishOperation(operationID, result: .succeeded(.wrapperBatch(result)))
            logger?.notice("Wrapper batch refresh completed")
        } catch {
            if Task.isCancelled {
                finishOperation(operationID, result: .cancelled)
                return
            }
            let wireError = Self.operationWireError(for: error)
            finishOperation(operationID, result: .failed(wireError))
            logger?.error("Wrapper batch refresh failed", errorCode: wireError.code)
        }
    }

    /// Refreshes every selected wrapper (wrapper.md §9.4); a running
    /// wrapper is skipped and listed, a failing one lands in `failed`.
    private func performRefreshAllWrappers(
        scope: RefreshAllScope,
        launcherOnly: Bool,
        operationID: WireOperationID
    ) async throws(RuntimeWireError) -> WrapperBatchResult {
        guard launcherBuild() != nil else {
            throw Self.wrapperWireError(for: .launcherTemplateInvalid("missing"))
        }
        let registry = await wrapperRegistryInstance()
        let service = packageQueryServiceInstance()
        try await service.open()
        try await attachPackageQueriesIfRuntimeIsReady(to: service)
        var knownPackages: Set<String>?
        if let list = try? await service.listPackages(
            RuntimeListPackagesRequest(filter: .all))
        {
            knownPackages = Set(list.packages.map(\.packageID.rawValue))
        }
        let validator = wrapperValidator(
            registry: registry, service: service, knownPackages: knownPackages)
        var refreshed: [RuntimePackageID] = []
        var skippedRunning: [RuntimePackageID] = []
        var failed: [WrapperBatchFailure] = []
        for entry in await registry.entries() {
            guard let packageID = RuntimePackageID(rawValue: entry.packageId) else {
                continue
            }
            if scope == .needingRefresh {
                let (url, _) = await resolvedWrapperURL(entry: entry, registry: registry)
                let needs =
                    (try? await validator.verify(url: url, deep: false))
                    .map { !$0.refreshReasons.isEmpty } ?? false
                if !needs {
                    continue
                }
            }
            if NSRunningApplication
                .runningApplications(withBundleIdentifier: entry.bundleId)
                .contains(where: { !$0.isTerminated })
            {
                skippedRunning.append(packageID)
                continue
            }
            guard wrapperCreationsInFlight.insert(packageID.rawValue).inserted else {
                skippedRunning.append(packageID)
                continue
            }
            do {
                _ = try await performRefreshWrapper(
                    packageID: packageID,
                    change: WrapperRefreshWire(launcherOnly: launcherOnly),
                    icon: nil,
                    operationID: operationID
                )
                refreshed.append(packageID)
            } catch {
                failed.append(
                    WrapperBatchFailure(
                        packageID: packageID,
                        error: error as? RuntimeWireError
                            ?? .runtime(
                                "internalError",
                                message: "APKRun's background service failed.")))
            }
            wrapperCreationsInFlight.remove(packageID.rawValue)
        }
        wrapperListCache = nil
        return WrapperBatchResult(
            refreshed: refreshed, skippedRunning: skippedRunning, failed: failed)
    }

    /// The latest statuses for the `wrappers.status` health check.
    private func wrapperStatusesSnapshot() -> [String: WrapperStatus] {
        latestWrapperStatuses
    }

    /// Completes a deferred placement (wrapper.md §6.3): the client, which
    /// the user already allowed to reach the protected folder, moved the
    /// staged bundle to `finalURL`. This runs §6.2 steps 12–13.
    public func placeStagedWrapper(
        stagingToken: String,
        finalURL: URL,
        bookmark: String?
    ) async throws(RuntimeWireError) -> WrapperInfo {
        let registry = await wrapperRegistryInstance()
        guard let pending = await registry.pendingEntry(stagingToken: stagingToken) else {
            throw Self.wrapperWireError(for: .stagingExpired)
        }
        // Tokens die with the staging cleanup and with age (errors.json
        // `wrapper.stagingExpired` documents 60 minutes). The client moved
        // the bundle out of `staging/<token>/`, so the age check reads the
        // token directory, which the daemon still owns.
        guard let stagingPath = pending.stagingPath else {
            throw Self.wrapperWireError(for: .stagingExpired)
        }
        let tokenDirectory = URL(fileURLWithPath: stagingPath)
            .deletingLastPathComponent()
        guard tokenDirectory.lastPathComponent == stagingToken,
            let created = try? FileManager.default.attributesOfItem(
                atPath: tokenDirectory.path)[.creationDate] as? Date,
            Date().timeIntervalSince(created) <= 60 * 60
        else {
            throw Self.wrapperWireError(for: .stagingExpired)
        }
        // The destination is the folder the daemon could not reach; the
        // client's security-scoped bookmark grants access for the checks
        // below (runtime-api.md §10.3).
        var accessURL = finalURL
        var securityScope: URL?
        var staleBookmark = false
        if let bookmarkData = bookmark.flatMap({ Data(base64Encoded: $0) }),
            !bookmarkData.isEmpty,
            let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &staleBookmark
            ),
            resolved.startAccessingSecurityScopedResource()
        {
            securityScope = resolved
            accessURL = resolved
        }
        defer { securityScope?.stopAccessingSecurityScopedResource() }
        // The client moved the bundle; it must be where it says it is and
        // still the wrapper the daemon signed (same package ID).
        guard
            FileManager.default.fileExists(atPath: accessURL.path),
            InfoPlistWriter.identity(of: accessURL)?.packageID == pending.packageId,
            WrapperCodeSign.cdhash(of: accessURL) == pending.cdhash
        else {
            throw Self.wrapperWireError(
                for: .bundleInvalid(finalURL, reason: .signatureInvalid))
        }
        guard let packageID = RuntimePackageID(rawValue: pending.packageId) else {
            throw .runtime("internal", message: "APKRun couldn't register the Mac app.")
        }
        let bookmarkData = bookmark.flatMap { Data(base64Encoded: $0) } ?? Data()
        do {
            try await registry.activate(
                bundleID: pending.bundleId, path: finalURL, bookmark: bookmarkData)
        } catch {
            throw Self.wrapperWireError(for: .registryUnavailable)
        }
        let installer = WrapperInstaller(sink: diagnostics?.logSink)
        let warning = installer.registerPlaced(at: finalURL)
        try? FileManager.default.removeItem(at: tokenDirectory)
        guard let entry = await registry.entry(bundleID: pending.bundleId) else {
            throw .runtime("internal", message: "APKRun couldn't register the Mac app.")
        }
        var warnings: [RuntimeWireError] = []
        if let warning {
            warnings.append(Self.wrapperWireError(for: warning))
        }
        return Self.wrapperInfo(for: entry, packageID: packageID, warnings: warnings)
    }

    /// Composes the wrapper icon from store-rendered layers: the `.icns`
    /// bytes plus the SHA-256 hex digest of the 1024 px master
    /// (wrapper.md §8.2–§8.5). The monochrome layer is stored but unused.
    /// The 1024px icon master for a rendered layer set (wrapper.md §8.2).
    static func composedIconMaster(
        kind: StoreIconKind, layers: [StoreIconLayer]
    ) -> CGImage? {
        func image(_ role: StoreIconRole) -> CGImage? {
            guard let png = layers.first(where: { $0.role == role })?.png,
                let source = CGImageSourceCreateWithData(png as CFData, nil)
            else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        switch kind {
        case .adaptive:
            guard let background = image(.background), let foreground = image(.foreground)
            else { return nil }
            return try? IconComposer.composeAdaptive(
                background: background, foreground: foreground)
        case .legacy:
            return image(.legacy).flatMap { try? IconComposer.composeLegacy($0) }
        }
    }

    static func composedIcon(
        kind: StoreIconKind, layers: [StoreIconLayer]
    ) -> (icns: Data, digest: String)? {
        guard let master = composedIconMaster(kind: kind, layers: layers),
            let masterPNG = try? IconComposer.pngData(master),
            let icns = try? IconsetWriter.icnsData(from: master)
        else { return nil }
        let digest = SHA256.hash(data: masterPNG).map { String(format: "%02x", $0) }.joined()
        return (icns, digest)
    }

    /// Returns the registry row of one package's wrapper (runtime-api.md §10.2).
    public func wrapperInfo(
        _ request: RuntimePackageRequest
    ) async throws(RuntimeWireError) -> WrapperInfo {
        let registry = await wrapperRegistryInstance()
        guard let entry = await registry.entry(packageID: request.packageID) else {
            throw Self.wrapperWireError(for: .wrapperNotFound(request.packageID))
        }
        return Self.wrapperInfo(for: entry, packageID: request.packageID)
    }

    /// The `listWrappers` result cache (wrapper.md §9.1: 60 s).
    private var wrapperListCache: (at: Date, entries: [WrapperListEntryWire])?

    /// Lists every registered wrapper with the status the validator
    /// computes (runtime-api.md §10.5, wrapper.md §9.1). Results are
    /// cached for 60 seconds; a bundle found at a new location updates
    /// its registry path and is reported `moved` once.
    public func listWrappers() async throws(RuntimeWireError) -> [WrapperListEntryWire] {
        if let cache = wrapperListCache,
            Date().timeIntervalSince(cache.at) < 60
        {
            return cache.entries
        }
        let registry = await wrapperRegistryInstance()
        let service = packageQueryServiceInstance()
        var knownPackages: Set<String>?
        do {
            try await service.open()
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
            let list = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            knownPackages = Set(list.packages.map(\.packageID.rawValue))
        } catch {
            knownPackages = nil
        }
        let validator = wrapperValidator(registry: registry, service: service, knownPackages: knownPackages)
        var entries: [WrapperListEntryWire] = []
        for entry in await registry.entries() {
            let result = await verifyWrapperEntry(
                entry: entry, registry: registry, validator: validator)
            guard let runtimeID = RuntimePackageID(rawValue: entry.packageId) else {
                continue
            }
            var summary = Self.wrapperSummary(for: entry, packageID: runtimeID)
            summary.bundleURL = result.url
            summary.status = WrapperStatus(
                state: result.state ?? .unknownPackage,
                refreshReasons: Set(result.reasons))
            entries.append(
                WrapperListEntryWire(
                    summary: summary, state: result.state, refreshReasons: result.reasons))
        }
        recordWrapperStatuses(
            entries.map {
                (packageID: $0.summary.packageID, status: $0.summary.status)
            })
        wrapperListCache = (Date(), entries)
        return entries
    }

    /// Verifies one registry entry (wrapper.md §9.1 checks 1–6): the path or
    /// a relocated bundle, with a foreign-bundle guard and an `.inaccessible`
    /// fallback for unreadable bundles.
    private func verifyWrapperEntry(
        entry: WrapperRegistryEntry,
        registry: WrapperRegistry,
        validator: WrapperValidator
    ) async -> (url: URL, state: WrapperState?, reasons: [WrapperRefreshReason]) {
        var (url, moved) = await resolvedWrapperURL(entry: entry, registry: registry)
        var state: WrapperState? = nil
        var reasons: [WrapperRefreshReason] = []
        do {
            var verification = try await validator.verify(url: url, deep: false)
            // A bundle that is not this entry's (e.g. another package's
            // wrapper now occupies the path) does not prove this entry's
            // state; relocate once by bundle ID + cdhash, then recheck.
            if (verification.bundleID != nil && verification.bundleID != entry.bundleId)
                || (verification.packageID != nil && verification.packageID != entry.packageId)
            {
                let relocated = await relocatedWrapperURL(
                    entry: entry, registry: registry, excluding: url)
                if let relocated {
                    url = relocated
                    moved = true
                    verification = try await validator.verify(url: url, deep: false)
                }
                if (verification.bundleID != nil && verification.bundleID != entry.bundleId)
                    || (verification.packageID != nil
                        && verification.packageID != entry.packageId)
                {
                    verification = WrapperValidator.Verification(bundleURL: url)
                    verification.state = .missing
                }
            }
            state = moved ? .moved(url) : verification.state
            reasons = verification.refreshReasons.sorted {
                String(describing: $0) < String(describing: $1)
            }
        } catch {
            // The bundle exists but could not be read or parsed — that
            // is a broken bundle, not an unknown package.
            state = .inaccessible
        }
        return (url, state, reasons)
    }

    /// Stores the latest wrapper statuses and posts `statusChanged` for the
    /// entries whose status changed (wrapper.md §12.1, coalesced per package).
    private func recordWrapperStatuses(
        _ statuses: [(packageID: RuntimePackageID, status: WrapperStatus)]
    ) {
        for item in statuses {
            let previous = latestWrapperStatuses[item.packageID.rawValue]
            latestWrapperStatuses[item.packageID.rawValue] = item.status
            if previous != item.status {
                eventHub.publishWrapperChange(
                    .statusChanged(item.packageID, item.status))
            }
        }
    }

    /// The apkrund-start + 60 s sweep (wrapper.md §9.1): a quick verification
    /// of every entry, refreshing `latestWrapperStatuses` and posting
    /// `statusChanged` for entries that changed. Low priority and quiet:
    /// failures only drop the sweep until the next list pass.
    private func runWrapperSweep() async {
        let registry = await wrapperRegistryInstance()
        let service = packageQueryServiceInstance()
        var knownPackages: Set<String>?
        do {
            try await service.open()
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
            let list = try await service.listPackages(
                RuntimeListPackagesRequest(filter: .all))
            knownPackages = Set(list.packages.map(\.packageID.rawValue))
        } catch {
            knownPackages = nil
        }
        let validator = wrapperValidator(
            registry: registry, service: service, knownPackages: knownPackages)
        var statuses: [(packageID: RuntimePackageID, status: WrapperStatus)] = []
        for entry in await registry.entries() {
            guard let runtimeID = RuntimePackageID(rawValue: entry.packageId) else {
                continue
            }
            let result = await verifyWrapperEntry(
                entry: entry, registry: registry, validator: validator)
            statuses.append(
                (
                    packageID: runtimeID,
                    status: WrapperStatus(
                        state: result.state ?? .unknownPackage,
                        refreshReasons: Set(result.reasons))
                ))
        }
        recordWrapperStatuses(statuses)
        wrapperListCache = nil
    }

    /// Removes a wrapper's registry entry, and with `trash` moves the
    /// bundle to the Trash first (wrapper.md §9.5). Wrappers are never
    /// deleted.
    public func removeWrapper(
        packageID: RuntimePackageID,
        trash: Bool
    ) async throws(RuntimeWireError) -> Bool {
        let registry = await wrapperRegistryInstance()
        guard let entry = await registry.entry(packageID: packageID) else {
            throw Self.wrapperWireError(for: .wrapperNotFound(packageID))
        }
        if trash {
            let (url, _) = await resolvedWrapperURL(entry: entry, registry: registry)
            // Only the registered wrapper itself goes to the Trash; anything
            // else placed at the recorded path stays untouched (§9.5).
            let isWrapper = WrapperInstaller(sink: diagnostics?.logSink)
                .isWrapperOf(packageID, at: url)
            if isWrapper, FileManager.default.fileExists(atPath: url.path) {
                var trashed: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                } catch {
                    throw .runtime(
                        "internalError",
                        message: "APKRun couldn't move the Mac app to the Trash.")
                }
            }
        }
        do {
            try await registry.remove(bundleID: entry.bundleId)
        } catch {
            throw .runtime(
                "internalError",
                message: "APKRun couldn't update the wrapper registry.")
        }
        wrapperListCache = nil
        eventHub.publishWrapperChange(.removed(packageID))
        return true
    }

    /// Scans `~/Applications` and `/Applications` for APKRun wrapper
    /// bundles (wrapper.md §7.2); with `register` the valid ones get a
    /// registry entry, which is how **Re-register Mac Apps** recovers a
    /// lost `registry.json`.
    public func rescanWrappers(
        register: Bool
    ) async throws(RuntimeWireError) -> RescanWrappersResult {
        let registry = await wrapperRegistryInstance()
        let directories = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
        ]
        var found: [String] = []
        var registered: [String] = []
        let service = packageQueryServiceInstance()
        var knownPackages: Set<String>?
        do {
            try await service.open()
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
            let list = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            knownPackages = Set(list.packages.map(\.packageID.rawValue))
        } catch {
            knownPackages = nil
        }
        let validator = wrapperValidator(registry: registry, service: service, knownPackages: knownPackages)
        for directory in directories {
            let bundles =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil
                ))?.filter { $0.pathExtension == "app" } ?? []
            for bundle in bundles {
                guard let plist = InfoPlistWriter.infoDictionary(of: bundle),
                    let packageID = plist["APKRunPackageID"] as? String,
                    let bundleID = plist["CFBundleIdentifier"] as? String
                else { continue }
                guard
                    let verification = try? await validator.verify(url: bundle, deep: false),
                    verification.state == .valid || verification.state == .unknownPackage,
                    verification.bundleID == nil || verification.bundleID == bundleID,
                    verification.packageID == nil || verification.packageID == packageID
                else { continue }
                found.append(bundle.path)
                // Registration marks the bundle trusted, so it needs the
                // strict deep signature check (wrapper.md §9.1 check 6).
                guard register,
                    await registry.entry(bundleID: bundleID) == nil,
                    let package = RuntimePackageID(rawValue: packageID),
                    (try? await validator.verify(url: bundle, deep: true))?.state == .valid,
                    let cdhash = verification.cdhash
                else { continue }
                var entry = WrapperRegistryEntry(
                    bundleId: bundleID,
                    packageId: packageID,
                    kind: verification.kind ?? .local,
                    state: .active,
                    path: bundle.path,
                    cdhash: cdhash,
                    launcherVersion: verification.launcherVersion ?? "0",
                    launcherAPI: verification.launcherAPI ?? "1.0",
                    fileName: bundle.deletingPathExtension().lastPathComponent,
                    displayName: (plist["CFBundleDisplayName"] as? String)
                        ?? bundle.deletingPathExtension().lastPathComponent,
                    createdAt: Date()
                )
                entry.approval = .user
                do {
                    try await registry.markPending(entry)
                    try await registry.activate(bundleID: bundleID, path: bundle, bookmark: Data())
                    registered.append(bundle.path)
                } catch {
                    logger?.error(
                        "wrapper rescan registration failed: \(bundle.path, .public)")
                }
            }
        }
        wrapperListCache = nil
        return RescanWrappersResult(found: found, registered: registered)
    }

    /// The validator verifyWrapper and listWrappers share; `knownPackages`
    /// nil (store unreachable) means the package check is skipped.
    private func wrapperValidator(
        registry: WrapperRegistry,
        service: EmbeddedPackageService,
        knownPackages: Set<String>?
    ) -> WrapperValidator {
        WrapperValidator(
            registry: registry,
            currentLauncher: launcherBuild(),
            packageExists: { knownPackages?.contains($0) ?? true },
            iconDigest: { packageID in
                guard let runtimeID = RuntimePackageID(rawValue: packageID) else {
                    return nil
                }
                guard
                    let rendered = await service.renderedIconLayers(for: runtimeID),
                    let composed = RuntimeHost.composedIcon(
                        kind: rendered.manifest.kind, layers: rendered.layers)
                else { return nil }
                return composed.digest
            },
            sink: diagnostics?.logSink
        )
    }

    /// The bundle URL of a registry entry: its recorded path, or a
    /// LaunchServices lookup by bundle ID when the path went missing
    /// (wrapper.md §9.1 check 1). `moved` is true when the registry path
    /// was updated to a new location — callers report `state.moved` once.
    private func resolvedWrapperURL(
        entry: WrapperRegistryEntry,
        registry: WrapperRegistry
    ) async -> (url: URL, moved: Bool) {
        let path = URL(fileURLWithPath: entry.path)
        if FileManager.default.fileExists(atPath: path.path),
            !path.path.contains("/.Trash/")
        {
            return (path, false)
        }
        if let relocated = await relocatedWrapperURL(
            entry: entry, registry: registry, excluding: nil)
        {
            return (relocated, true)
        }
        return (path, false)
    }

    /// The wrapper's real location when its recorded path does not hold
    /// its bundle: LaunchServices knows apps by bundle ID, and the
    /// cdhash keeps a same-ID impostor from being adopted.
    private func relocatedWrapperURL(
        entry: WrapperRegistryEntry,
        registry: WrapperRegistry,
        excluding: URL?
    ) async -> URL? {
        for candidate in NSWorkspace.shared.urlsForApplications(
            withBundleIdentifier: entry.bundleId)
        {
            guard candidate != excluding else { continue }
            guard WrapperCodeSign.cdhash(of: candidate) == entry.cdhash else { continue }
            let bookmark = try? candidate.bookmarkData()
            try? await registry.updateLocation(
                bundleID: entry.bundleId, path: candidate, bookmark: bookmark ?? Data())
            return candidate
        }
        return nil
    }

    /// Builds the wire record from a registry entry; `warnings` carries
    /// non-fatal outcomes such as a registration failure.
    private static func wrapperInfo(
        for entry: WrapperRegistryEntry,
        packageID: RuntimePackageID,
        warnings: [RuntimeWireError] = []
    ) -> WrapperInfo {
        WrapperInfo(
            summary: wrapperSummary(for: entry, packageID: packageID),
            fileName: entry.fileName,
            customization: WrapperCustomizationWire(
                displayName: entry.customization.displayName,
                customIcon: entry.customization.iconFile != nil
            ),
            signer: .adHoc,
            cdhash: entry.cdhash,
            launcherAPI: launcherAPIVersion(entry.launcherAPI) ?? APIVersion(major: 1, minor: 0),
            formatVersion: entry.formatVersion,
            iconDigest: entry.iconDigest.flatMap { RuntimeSHA256Digest(rawValue: "sha256:\($0)") },
            lastValidatedAt: entry.lastValidatedAt,
            warnings: warnings
        )
    }

    /// Maps a registry entry to its wire summary.
    private static func wrapperSummary(
        for entry: WrapperRegistryEntry,
        packageID: RuntimePackageID
    ) -> WrapperSummary {
        WrapperSummary(
            packageID: packageID,
            bundleID: entry.bundleId,
            displayName: entry.displayName,
            kind: WrapperKindTag(rawValue: entry.kind.rawValue) ?? .local,
            bundleURL: URL(fileURLWithPath: entry.path),
            status: WrapperStatus(state: .valid),
            approval: entry.approval == .user ? .user : .generated,
            launcherVersion: entry.launcherVersion,
            createdAt: entry.createdAt,
            refreshedAt: entry.refreshedAt
        )
    }

    /// The daemon's wrapper registry, created on first use with startup
    /// `recover()` applied (wrapper-json.md §4.4).
    func wrapperRegistryInstance() async -> WrapperRegistry {
        if let wrapperRegistry {
            return wrapperRegistry
        }
        if let wrapperRegistryLoadTask {
            return await wrapperRegistryLoadTask.value
        }
        let loadTask = Task { () -> WrapperRegistry in
            let registry = WrapperRegistry(paths: paths, sink: diagnostics?.logSink)
            _ = await registry.load()
            await registry.recover { WrapperCodeSign.cdhash(of: $0) }
            return registry
        }
        wrapperRegistryLoadTask = loadTask
        let registry = await loadTask.value
        wrapperRegistry = registry
        registerWrapperHealthChecks(registry: registry)
        return registry
    }

    /// Registers the `wrappers.*` health checks once (wrapper.md §14).
    private func registerWrapperHealthChecks(registry: WrapperRegistry) {
        guard !wrapperHealthChecksRegistered, let checks = diagnostics?.healthChecks else { return }
        wrapperHealthChecksRegistered = true
        Task {
            try? await checks.register(WrapperHealthChecks.registry(registry))
            try? await checks.register(WrapperHealthChecks.registration(registry))
            if let build = launcherBuild() {
                try? await checks.register(
                    WrapperHealthChecks.template(executableURL: build.executableURL))
            }
            try? await checks.register(
                WrapperStatusCheck { [weak self] in
                    await self?.wrapperStatusesSnapshot() ?? [:]
                })
            let launcherAPI = self.launcherBuild()?.launcherAPI
            try? await checks.register(
                WrapperLauncherCheck(registry: registry) { launcherAPI })
        }
    }

    /// The launcher template inside this APKRun.app, derived from the daemon's
    /// own location inside the bundle. `nil` outside an `.app` (development
    /// runs), which skips the template check and refresh reason 6.
    private func launcherBuild() -> LauncherBuild? {
        var url = executableURL.deletingLastPathComponent()
        while url.path != "/", url.pathExtension != "app" {
            url.deleteLastPathComponent()
        }
        guard url.pathExtension == "app" else { return nil }
        let templateApp = url.appendingPathComponent("Contents/Helpers/APKRunLauncher.app")
        let executable = templateApp.appendingPathComponent("Contents/MacOS/APKRunLauncher")
        guard FileManager.default.fileExists(atPath: executable.path) else { return nil }
        let plist =
            (try? Data(contentsOf: templateApp.appendingPathComponent("Contents/Info.plist")))
            .flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil)
            } as? [String: Any] ?? [:]
        return LauncherBuild(
            launcherAPI: plist["APKRunLauncherAPI"] as? String ?? "1.0",
            launcherVersion: plist["CFBundleShortVersionString"] as? String ?? "0.1.0",
            executableURL: executable
        )
    }

    /// Parses a `major.minor` launcher API string (a missing minor is 0).
    private static func launcherAPIVersion(_ string: String) -> APIVersion? {
        let parts = string.split(separator: ".", maxSplits: 1).map(String.init)
        guard let major = Int(parts.first ?? "") else { return nil }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return APIVersion(major: major, minor: minor)
    }

    /// Opens the window owner of a package (runtime-daemon.md §7.2): the
    /// registered wrapper when checks 1–3 of wrapper.md §9.1 pass and the
    /// cdhash matches, otherwise the generic launcher with `--package`.
    private func openWindowOwner(for packageID: RuntimePackageID) async {
        guard let registry = try? await wrapperRegistryInstance() else { return }
        if let entry = await registry.entry(packageID: packageID),
            entry.state == .active,
            let bundleURL = await launchBundleURL(for: entry, registry: registry),
            await WorkspaceOpener.openApplication(at: bundleURL)
        {
            return
        }
        guard let appURL = containingAppURL() else { return }
        let launcherURL = appURL.appendingPathComponent("Contents/Helpers/APKRunLauncher.app")
        guard FileManager.default.fileExists(atPath: launcherURL.path) else { return }
        await WorkspaceOpener.openApplication(
            at: launcherURL, arguments: ["--package", packageID.rawValue])
    }

    /// Step 1 of wrapper.md §9.1 for the launch path: the bundle at the
    /// registered path, else the LaunchServices candidates for the bundle ID,
    /// keeping the first whose checks 2–3 pass. A found new location is written
    /// back to the registry (§9.1's moved-wrapper rule).
    private func launchBundleURL(
        for entry: WrapperRegistryEntry,
        registry: WrapperRegistry
    ) async -> URL? {
        let registeredURL = URL(fileURLWithPath: entry.path)
        var candidates = [registeredURL]
        if !FileManager.default.fileExists(atPath: registeredURL.path) {
            candidates = WorkspaceOpener.applicationURLs(bundleIdentifier: entry.bundleId)
        }
        for candidate in candidates {
            guard bundlePassesLaunchChecks(entry: entry, at: candidate) else { continue }
            if candidate.path != entry.path {
                let bookmark = (try? candidate.bookmarkData()) ?? Data()
                try? await registry.updateLocation(
                    bundleID: entry.bundleId, path: candidate, bookmark: bookmark)
            }
            return candidate
        }
        return nil
    }

    /// Checks 1–3 of wrapper.md §9.1 for one candidate: the bundle exists
    /// outside the Trash, is readable, and identifier and cdhash match the
    /// registry entry.
    private func bundlePassesLaunchChecks(entry: WrapperRegistryEntry, at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
            !url.path.contains("/.Trash/"),
            FileManager.default.isReadableFile(atPath: url.path)
        else {
            return false
        }
        guard let plist = InfoPlistWriter.infoDictionary(of: url),
            (plist["CFBundleIdentifier"] as? String) == entry.bundleId,
            let cdhash = WrapperCodeSign.cdhash(of: url),
            cdhash == entry.cdhash
        else {
            return false
        }
        return true
    }

    // MARK: - Wrapper approval (wrapper.md §7.3)

    private var approvalService: WrapperApprovalService?

    /// The approval service, created on the shared registry on first use.
    private func approvalServiceInstance() async throws(RuntimeWireError) -> WrapperApprovalService {
        if let approvalService { return approvalService }
        let registry = try await wrapperRegistryInstance()
        let service = WrapperApprovalService(
            registry: registry,
            announce: { [weak self] announcement in
                Task { await self?.announceApproval(announcement) }
            },
            packageInstalled: { [weak self] packageID in
                guard let self else { return false }
                return await self.packageIsInstalled(packageID)
            },
            iconProvider: { _ in nil }
        )
        approvalService = service
        return service
    }

    /// Whether the store has an installed managed record for the package.
    private func packageIsInstalled(_ packageID: RuntimePackageID) async -> Bool {
        let service = packageQueryServiceInstance()
        try? await service.open()
        guard
            let details = try? await service.packageInfo(
                RuntimePackageRequest(packageID: packageID))
        else {
            return false
        }
        return details.summary.managed && details.summary.state == .installed
    }

    /// Forwards approval announcements to subscribers and wakes APKRun.app.
    private func announceApproval(_ announcement: WrapperApprovalService.Announcement) {
        switch announcement {
        case .requested(let prompt):
            eventHub.publishWrapperChange(.approvalRequested(prompt))
            // No connected UI client → open APKRun.app with --approve
            // (wrapper.md §7.3 step 4, host-ui.md §3.3).
            if !eventHub.hasSubscriber(clientKind: .app, topic: .wrappers),
                let appURL = containingAppURL()
            {
                Task {
                    await WorkspaceOpener.openApplication(at: appURL, arguments: ["--approve"])
                }
            }
        case .resolved(let approvalID):
            eventHub.publishWrapperChange(.approvalResolved(approvalID))
        case .created(let summary):
            eventHub.publishWrapperChange(.created(summary))
        }
    }

    /// The `.app` bundle that contains this daemon (like `launcherBuild()`).
    private func containingAppURL() -> URL? {
        var url = executableURL.deletingLastPathComponent()
        while url.path != "/", url.pathExtension != "app" {
            url.deleteLastPathComponent()
        }
        return url.pathExtension == "app" ? url : nil
    }

    /// The broker's `requestApproval` op (runtime-api.md §3.4).
    public func requestApproval(_ request: ApprovalRequest) async throws(RuntimeWireError)
        -> ApprovalReply
    {
        let service = try await approvalServiceInstance()
        do {
            return try await service.request(
                bundleURL: request.bundleURL,
                bundleID: request.bundleID,
                packageID: request.packageID
            )
        } catch {
            if case .approvalBusy = error { throw Self.approvalBusyError }
            throw Self.wrapperWireError(for: error)
        }
    }

    /// The prompts APKRun.app shows (runtime-api.md `pendingApprovals`).
    public func pendingApprovals() async -> [ApprovalPrompt] {
        guard let service = try? await approvalServiceInstance() else { return [] }
        return await service.pendingPrompts()
    }

    /// APKRun.app's answer to a prompt (runtime-api.md `decideApproval`).
    public func decideApproval(_ request: DecideApprovalRequest) async throws(RuntimeWireError) {
        let service = try await approvalServiceInstance()
        do {
            _ = try await service.decide(approvalID: request.approvalID, allow: request.allow)
        } catch {
            throw Self.wrapperWireError(for: error)
        }
    }

    /// The denied list of Settings → Privacy (runtime-api.md `deniedWrappers`).
    public func deniedWrappers() async -> [DeniedWrapper] {
        guard let service = try? await approvalServiceInstance() else { return [] }
        return await service.deniedWrappers()
    }

    /// Removes a denied entry (runtime-api.md `clearWrapperDenial`).
    public func clearWrapperDenial(_ request: ClearWrapperDenialRequest) async throws(RuntimeWireError) {
        let service = try await approvalServiceInstance()
        do {
            try await service.clearDenial(bundleID: request.bundleID)
        } catch {
            throw Self.wrapperWireError(for: error)
        }
    }

    private static let approvalBusyError = RuntimeWireError(
        domain: "runtime",
        code: "runtime.busy",
        message: "Too many approval requests. Try again in a minute."
    )

    /// Maps a wrapper failure to the wire error type of the control endpoint.
    private static func wrapperWireError(for failure: WrapperFailure) -> RuntimeWireError {
        let entry = ErrorCatalog.entry(for: failure.qualifiedCode)
        let message =
            entry?.message?["en"].map {
                interpolate($0, parameters: failure.parameters)
            } ?? failure.code
        let remediation = entry?.remediation?["en"].map {
            interpolate($0, parameters: failure.parameters)
        }
        return RuntimeWireError(
            domain: "wrapper",
            code: failure.qualifiedCode,
            message: message,
            remediation: remediation,
            parameters: Self.wireParameters(for: failure)
        )
    }

    /// The error's catalog parameters as plain strings for the wire — the
    /// `stagingToken` of `destinationNotAccessible` is how the client names
    /// the staged bundle it must move (wrapper.md §6.3).
    private static func wireParameters(
        for failure: WrapperFailure
    ) -> [String: String] {
        failure.parameters.reduce(into: [:]) { result, entry in
            switch entry.value {
            case .text(let text), .fileName(let text):
                result[entry.key] = text
            case .count(let count):
                result[entry.key] = String(count)
            case .bytes(let bytes):
                result[entry.key] = String(bytes)
            case .duration:
                break
            }
        }
    }

    private static func interpolate(
        _ template: String,
        parameters: [String: ErrorParameter]
    ) -> String {
        var result = template
        for (name, parameter) in parameters {
            let value: String
            switch parameter {
            case .text(let text), .fileName(let text):
                value = text
            case .count(let count):
                value = String(count)
            case .bytes(let bytes):
                value = String(bytes)
            case .duration:
                continue
            }
            result = result.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return result
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
            guestAgentProtocolVersion: guestAgentStatus?.protocolVersion?.description,
            provisioning: provisioningState
        )
    }

    /// Whether the daemon can exit after its idle grace period without cancelling an operation.
    public func canExitWhenIdle() async -> Bool {
        guard hasStarted, !isShuttingDown, activeLifecycleOperations == 0 else {
            return false
        }
        let runtimeState = await supervisor?.state
        // runtime-daemon.md §2.4: do not exit while update work is due
        // inside the idle grace window — a check that would start before
        // the grace ends keeps the daemon alive.
        let updateDueSoon: Bool
        if let scheduler = updateScheduler,
            let next = await scheduler.earliestWakeAt()
        {
            updateDueSoon = next < Date().addingTimeInterval(120)
        } else {
            updateDueSoon = false
        }
        return !isShuttingDown
            && activeLifecycleOperations == 0
            && (runtimeState == nil || runtimeState == .stopped)
            && !updateDueSoon
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
        for continuation in updateEventContinuations.values {
            continuation.yield(.stateChanged(Self.wireRuntimeState(for: snapshot.state)))
        }
        if case .booting = snapshot.state {
            publishBootProgress(generation: bootProgressGeneration)
        }
        if case .ready = snapshot.state {
            startClipboardRelay()
        } else if case .stopped = snapshot.state {
            stopClipboardRelay()
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
        await updateScheduler?.stop()
        // Unanswered approval prompts must not hold the request drain:
        // their launchers get `timedOut` instead of the ten-minute wait.
        await approvalService?.cancelAll()
        guard hasStarted else {
            hostState = "stopped"
            completeShutdown()
            return
        }
        await waitForPackageMutations()
        if let service = headlessSessionService as? DaemonHeadlessSessionService {
            await service.shutdown()
        }
        headlessSessionService = nil
        // Mark an in-flight VM start for cancellation before waiting for any storage work to finish.
        await supervisor?.stop(reason: .hostShutdown)
        await waitForLifecycleOperations()
        // A start that was already inside RuntimeSupervisor may have finished its cancellation path
        // while this actor was waiting. Stop once more before recording a clean process exit.
        await supervisor?.stop(reason: .hostShutdown)
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

    func beginPackageMutation() throws(RuntimeHostError) {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting else {
            throw .invalidTransition
        }
        try beginLifecycleOperation()
        activePackageMutations += 1
    }

    func finishPackageMutation() {
        activePackageMutations -= 1
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

    func waitForStartupCompletion(
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

    func makeHeadlessSessionService() async throws(RuntimeWireError) -> any RuntimeSessionService {
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
            logSink: diagnostics?.logSink
        )
        await attachPerfObservers(to: service)
        await service.setSessionChangeObserver { [weak self] snapshot in
            guard let change = Self.sessionChange(for: snapshot) else { return }
            self?.eventHub.publishSessionChange(change)
        }
        headlessSessionService = service
        await wireUpdateGateSessionHooks()
        return service
    }

    // MARK: - Performance records and statistics (diagnostics.md §4.3, §9.3; #71)

    /// Marks `WRAPPER_PROCESS_START`/`APP_LAUNCH_REQUEST` from the launcher's own
    /// stamps and returns the record bookkeeping (diagnostics.md §4.2, §4.3).
    private func beginLaunchRecord(_ request: RuntimeLaunchRequest) async -> PendingLaunchRecord {
        let now = ContinuousClock.now
        let base: ContinuousClock.Instant
        if let timing = request.launchTiming {
            base = Self.instant(continuousTicks: timing.processStart)
            let requestInstant = Self.instant(continuousTicks: timing.requestSent)
            let xpcDelayMs = Self.milliseconds(from: requestInstant, to: now)
            let timeline = diagnostics?.perfTimeline
            if let timeline {
                Perf.mark(.wrapperProcessStart, at: base, timeline: timeline)
                Perf.mark(
                    .appLaunchRequest,
                    at: requestInstant,
                    ["xpcDelayMs": .double(max(0, xpcDelayMs))],
                    timeline: timeline
                )
            }
        } else {
            base = now
        }
        let supervisorState = await supervisor?.state
        // `warm` only when Android is already up; a boot started by this launch is
        // `cold`, and the provisioning boot is `firstBoot` (diagnostics.md §4.3).
        let launchState: String
        switch supervisorState {
        case .ready, .stopping: launchState = "warm"
        case .booting, .stopped, .failed, nil: launchState = "cold"
        }
        return PendingLaunchRecord(
            base: base,
            packageID: request.packageID.rawValue,
            versionCode: nil,
            sessionID: nil,
            operationID: OperationContext.currentWireID,
            launchState: launchState
        )
    }

    /// The `mach_timebase_info` scale, cached: `mach_continuous_time` ticks are
    /// not nanoseconds on every machine (diagnostics.md §4.2).
    private static let machTimebaseNanosPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    /// Converts `mach_continuous_time` ticks to nanoseconds.
    private static func nanoseconds(machTicks: UInt64) -> UInt64 {
        UInt64((Double(machTicks) * machTimebaseNanosPerTick).rounded())
    }

    /// Converts `mach_continuous_time` ticks to a clock instant.
    private static func instant(continuousTicks: UInt64) -> ContinuousClock.Instant {
        let deltaTicks =
            Int64(bitPattern: continuousTicks) &- Int64(bitPattern: mach_continuous_time())
        return ContinuousClock.now.advanced(
            by: .nanoseconds(Int64(Double(deltaTicks) * machTimebaseNanosPerTick)))
    }

    /// Milliseconds between two instants.
    private static func milliseconds(
        from earlier: ContinuousClock.Instant,
        to later: ContinuousClock.Instant
    ) -> Double {
        let components = (later - earlier).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// Attaches the session to a pending launch record; `FIRST_FRAME_DISPLAYED` or
    /// the session's end finalizes it. A first frame that arrived before the
    /// record (the notification wins the race once, per session) is in
    /// `firstFramesBeforeRecord`, so the launch finalizes as `shown` at once.
    private func completeLaunchRecord(_ record: PendingLaunchRecord, sessionID: UUID) {
        var pending = record
        pending.sessionID = sessionID
        if firstFramesBeforeRecord.remove(sessionID) != nil {
            finalizeLaunchRecord(pending, outcome: "shown", at: ContinuousClock.now)
            return
        }
        pendingLaunchRecords[sessionID] = pending
    }

    /// Sessions whose first frame arrived while no pending record existed.
    private var firstFramesBeforeRecord: Set<UUID> = []

    /// Writes a `failed(<code>)` record for a launch that never opened a session.
    private func failLaunchRecord(_ record: PendingLaunchRecord, code: String) {
        let pending =
            record.sessionID.flatMap { pendingLaunchRecords.removeValue(forKey: $0) }
            ?? record
        finalizeLaunchRecord(pending, outcome: "failed(\(code))", at: ContinuousClock.now)
    }

    /// The session's first frame: outcome `shown`. A notification that arrives
    /// before the launch's record is registered is held for
    /// `completeLaunchRecord` (the notification fires only once per session).
    private func noteSessionFirstFrame(_ sessionID: UUID) {
        guard let pending = pendingLaunchRecords.removeValue(forKey: sessionID) else {
            firstFramesBeforeRecord.insert(sessionID)
            return
        }
        finalizeLaunchRecord(pending, outcome: "shown", at: ContinuousClock.now)
    }

    /// A session that ended before its first frame: `ended(<reason>)`; after the
    /// frame was shown the record is already written.
    private func noteSessionEnded(_ sessionID: UUID, reason: String) {
        firstFramesBeforeRecord.remove(sessionID)
        Task { await clipboardCoordinator?.noteSessionEnded(sessionID: sessionID) }
        guard let pending = pendingLaunchRecords.removeValue(forKey: sessionID) else {
            return
        }
        finalizeLaunchRecord(pending, outcome: "ended(\(reason))", at: ContinuousClock.now)
    }

    /// Assembles markers from the timeline window and appends the record.
    private func finalizeLaunchRecord(
        _ record: PendingLaunchRecord,
        outcome: String,
        at end: ContinuousClock.Instant
    ) {
        var markers: [String: Double] = [:]
        if let timeline = diagnostics?.perfTimeline {
            for event in timeline.snapshot()
            where event.time >= record.base && Self.launchMarkers.contains(event.marker) {
                // A marker that names another operation belongs to another
                // launch; contextless markers and markers of this operation
                // join the record.
                if let context = event.operationContext, context.operationID.wireValue != record.operationID {
                    continue
                }
                // A marker attributed to another session (for example the first
                // frame of a concurrently launched app) is not this launch's.
                if case .string(let session)? = event.attributes["session"],
                    session != record.sessionID?.uuidString
                {
                    continue
                }
                markers[event.marker.rawValue] = Self.milliseconds(from: record.base, to: event.time)
            }
        }
        perfRecords?.appendLaunch(
            LaunchRecord(
                packageID: record.packageID,
                versionCode: record.versionCode,
                sessionID: record.sessionID?.uuidString,
                operationID: record.operationID,
                launchState: record.launchState,
                windowMode: "secondaryDisplay",
                build: buildInfo.buildNumber,
                image: image?.version.description ?? "",
                gpuProfile: "drmVirgl",
                markers: markers,
                totalMs: Self.milliseconds(from: record.base, to: end),
                outcome: outcome
            ))
    }

    /// Markers that join a launch record (diagnostics.md §4.3).
    private static let launchMarkers: Set<PerfMarker> = [
        .wrapperProcessStart, .appLaunchRequest, .displayAttached, .activityStarted,
        .firstFrame, .firstFrameDisplayed, .updateCheckStart, .updateCheckEnd,
    ]

    /// Connects the session service's perf hooks once (idempotent).
    private func attachPerfObservers(to service: DaemonHeadlessSessionService) async {
        await service.setPerfObservers(
            firstFrame: { [weak self] sessionID in
                guard case .app(let uuid) = sessionID else {
                    return
                }
                Task { await self?.noteSessionFirstFrame(uuid) }
            },
            sessionEnded: { [weak self] sessionID, reason in
                guard case .app(let uuid) = sessionID else {
                    return
                }
                Task { await self?.noteSessionEnded(uuid, reason: reason) }
            }
        )
    }

    /// The developer-mode gate for `perfStatistics` and `frameStatistics`
    /// (diagnostics.md §9.3): `developer.enabled` in `settings.json`.
    private func requireDeveloperMode() throws(RuntimeWireError) {
        guard GlobalSettings.load(from: paths.settingsFile).developerEnabled else {
            throw .runtime(
                "developerModeRequired",
                message: "Developer mode is turned off.",
                remediation:
                    "Turn on Developer mode in Settings → Advanced, or run: apkrun config set developer.enabled true"
            )
        }
    }

    /// `perfStatistics`: markers, input histograms, session graphics, and an
    /// on-demand metrics snapshot; `reset` clears them (diagnostics.md §9.3).
    public func perfStatistics(
        _ request: PerfStatisticsRequest
    ) async throws(RuntimeWireError) -> WirePerfStatistics {
        try requireDeveloperMode()
        let events = (diagnostics?.perfTimeline.snapshot() ?? [])
            .filter { $0.time >= statisticsSinceInstant }
        let markers = Self.markerStatistics(from: events)
        let input = InputLatencyRecorder.shared.histograms().map {
            WireInputHistogram(segment: $0.segment, boundsUs: $0.boundsUs, counts: $0.counts)
        }
        let sessions = await sessionGraphicsStatistics(sessionID: nil)
        let metrics = metricsSnapshot()
        let result = WirePerfStatistics(
            since: statisticsSinceDate,
            markers: markers,
            input: input,
            sessions: sessions,
            metrics: metrics
        )
        if request.reset {
            diagnostics?.perfTimeline.clear()
            InputLatencyRecorder.shared.reset()
            statisticsSinceInstant = .now
            statisticsSinceDate = Date()
        }
        return result
    }

    /// `frameStatistics`: per-session graphics; never starts Android
    /// (diagnostics.md §9.3, runtime-api.md §13.1).
    public func frameStatistics(sessionID: UUID?) async throws(RuntimeWireError)
        -> [SessionGraphicsStatistics]
    {
        try requireDeveloperMode()
        return await sessionGraphicsStatistics(sessionID: sessionID)
    }

    /// Session graphics rows from the headless session service, or `[]` before
    /// Android has ever run (the read itself never starts it).
    private func sessionGraphicsStatistics(sessionID: UUID?) async -> [SessionGraphicsStatistics] {
        guard let service = headlessSessionService as? DaemonHeadlessSessionService else {
            return []
        }
        let rows = await service.sessionGraphicsStatistics()
        guard let sessionID else {
            return rows.map(\.statistics)
        }
        return rows.filter { $0.sessionID == sessionID }.map(\.statistics)
    }

    /// Per-marker segment distributions. A marker's duration is its segment
    /// inside one operation: the gap to the previous event carrying the same
    /// operation context (diagnostics.md §9.3). Events without a context share
    /// one group.
    private static func markerStatistics(from events: [PerfEvent]) -> [WireMarkerStatistics] {
        var lastSeen: [String: ContinuousClock.Instant] = [:]
        var durations: [String: [Int64]] = [:]
        var counts: [String: Int] = [:]
        for event in events.sorted(by: { $0.time < $1.time }) {
            let name = event.marker.rawValue
            let context = event.operationContext?.operationID.wireValue ?? ""
            counts[name, default: 0] += 1
            if let previous = lastSeen[context] {
                let components = (event.time - previous).components
                let us =
                    components.seconds * 1_000_000
                    + components.attoseconds / 1_000_000_000_000
                durations[name, default: []].append(us)
            }
            lastSeen[context] = event.time
        }
        return counts.keys.sorted().map { name in
            let values = (durations[name] ?? []).sorted()
            let p50 = values.isEmpty ? 0 : values[values.count / 2]
            let p95 =
                values.isEmpty
                ? 0
                : values[min(values.count - 1, (values.count * 95 + 99) / 100 - 1)]
            return WireMarkerStatistics(
                name: name,
                count: counts[name] ?? 0,
                p50Us: p50,
                p95Us: p95,
                maxUs: values.last ?? 0
            )
        }
    }

    /// The on-demand metrics snapshot of diagnostics.md §5.
    private func metricsSnapshot() -> WireMetricsSnapshot {
        let sampler = MetricsSampler()
        let daemon = sampler.daemonMetrics()
        var vmFootprint: Int64?
        if let vmStart = diagnostics?.perfTimeline.snapshot().last(where: { $0.marker == .vmStart }) {
            // The marker's instant converted back to mach uptime nanoseconds (OQ-06).
            let elapsed = ContinuousClock.now - vmStart.time
            let elapsedNs =
                UInt64(max(0, elapsed.components.seconds)) * 1_000_000_000
                + UInt64(max(0, elapsed.components.attoseconds) / 1_000_000_000)
            let vmUptime = Self.nanoseconds(machTicks: mach_continuous_time()) &- elapsedNs
            if let pid = sampler.findVirtualMachineService(afterUptimeNanos: vmUptime) {
                vmFootprint = sampler.physFootprint(of: pid)
            }
        }
        return WireMetricsSnapshot(
            sampledAt: Date(),
            vmServiceFootprintBytes: vmFootprint,
            daemonFootprintBytes: daemon.footprintBytes,
            daemonResidentBytes: daemon.residentBytes,
            daemonCPUUserUs: daemon.cpuUserUs,
            daemonCPUSystemUs: daemon.cpuSystemUs
        )
    }

    // MARK: - First-run provisioning and Reset Android (#67)

    /// The `state.json` provisioning record under the data root.
    private var provisioningStore: RuntimeStateStore {
        RuntimeStateStore(fileURL: paths.stateFile)
    }

    /// Records and publishes a provisioning state (runtime-daemon.md §9.2).
    private func setProvisioningState(_ state: WireProvisioningState) {
        provisioningState = state
        eventHub.publishRuntimeChange(.provisioningChanged(state))
    }

    /// The provisioning step matching the part of `performSetup` currently running.
    private func provisioningStep(for state: WireProvisioningState) -> ProvisioningStep {
        switch state {
        case .checkingHost: .checkingHost
        case .installingImage: .installingImage
        case .creatingInstance: .creatingInstance
        case .firstBoot: .firstBoot
        case .installingAgents: .installingAgents
        case .verifying: .verifying
        default: .checkingHost
        }
    }

    /// Begins or resumes first-run provisioning and returns its operation handle.
    func beginSetup(
        _ request: SetupRequest,
        files: [FileHandle],
        operationID requestedID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async throws(RuntimeWireError) -> OperationHandle {
        guard !isShuttingDown else {
            throw RuntimeWireError.runtime(
                "hostShuttingDown",
                message: "APKRun's background service is shutting down.",
                remediation: "Start APKRun again."
            )
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
            guard existing.handle.kind == .setup, existing.requestPayload == requestPayload else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request."
                )
            }
            return existing.handle
        }
        if let running = trackedOperations.values.first(where: {
            $0.handle.kind == .setup && $0.snapshot.result == nil
        }) {
            return running.handle
        }
        do {
            try beginLifecycleOperation()
        } catch {
            throw Self.sessionWireError(for: error)
        }
        let handle = OperationHandle(operationID: requestedID, kind: .setup)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .setup,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(stage: "checkingHost", message: "Checking this Mac…")
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            snapshot: snapshot,
            isCancellable: false,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: requestedID)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSetupOperation(request, files: files, operationID: requestedID)
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    /// Begins a Reset Android operation and returns its handle (runtime-daemon.md §9.5).
    func beginResetAndroid(
        _ request: ResetAndroidRequest,
        operationID requestedID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async throws(RuntimeWireError) -> OperationHandle {
        guard request.confirmed else {
            throw .runtime(
                "malformedRequest",
                message: "Reset Android needs an explicit confirmation."
            )
        }
        guard !isShuttingDown else {
            throw RuntimeWireError.runtime(
                "hostShuttingDown",
                message: "APKRun's background service is shutting down.",
                remediation: "Start APKRun again."
            )
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
            guard existing.handle.kind == .resetAndroid,
                existing.requestPayload == requestPayload
            else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request."
                )
            }
            return existing.handle
        }
        if let running = trackedOperations.values.first(where: {
            $0.handle.kind == .resetAndroid && $0.snapshot.result == nil
        }) {
            return running.handle
        }
        do {
            try beginLifecycleOperation()
        } catch {
            throw Self.sessionWireError(for: error)
        }
        let handle = OperationHandle(operationID: requestedID, kind: .resetAndroid)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .resetAndroid,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(stage: "resetting", message: "Resetting Android…")
        )
        trackedOperations[requestedID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            snapshot: snapshot,
            isCancellable: false,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: requestedID)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runResetAndroidOperation(request, operationID: requestedID)
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    private func runSetupOperation(
        _ request: SetupRequest,
        files: [FileHandle],
        operationID: WireOperationID
    ) async {
        defer { finishLifecycleOperation() }
        do {
            try await performSetup(request, files: files, operationID: operationID)
            finishOperation(operationID, result: .succeeded(.none))
        } catch {
            if case .firstBoot = error.step, let record = try? await provisioningStore.load() {
                var record = record
                record.failedFirstBoots += 1
                try? await provisioningStore.save(record)
            }
            setProvisioningState(.failed(step: error.step, error: error.stateError))
            finishOperation(operationID, result: .failed(error.wireError))
            logger?.error("Provisioning failed at \(error.step.rawValue, .public)", errorCode: error.wireError.code)
        }
    }

    private func runResetAndroidOperation(
        _ request: ResetAndroidRequest,
        operationID: WireOperationID
    ) async {
        defer { finishLifecycleOperation() }
        do {
            try await performResetAndroid(request, operationID: operationID)
            finishOperation(operationID, result: .succeeded(.none))
        } catch {
            let wireError = Self.operationWireError(for: error)
            finishOperation(operationID, result: .failed(wireError))
            logger?.error("Reset Android failed", errorCode: wireError.code)
        }
    }

    /// A provisioning step's error: the operation-result wire error and the richer
    /// `WireError` carried by the `.failed` provisioning state.
    private struct ProvisioningStepFailure: Error {
        let step: ProvisioningStep
        let wireError: RuntimeWireError
        let stateError: RuntimeAPI.WireError

        init(step: ProvisioningStep, wireError: RuntimeWireError) {
            self.step = step
            self.wireError = wireError
            stateError = RuntimeAPI.WireError(domain: wireError.domain, code: wireError.code)
        }

        init(step: ProvisioningStep, wireError: RuntimeWireError, stateError: RuntimeAPI.WireError) {
            self.step = step
            self.wireError = wireError
            self.stateError = stateError
        }
    }

    /// Runs the §9.2 step machine; already-finished steps are skipped so a quit mid-setup resumes.
    private func performSetup(
        _ request: SetupRequest,
        files: [FileHandle],
        operationID: WireOperationID
    ) async throws(ProvisioningStepFailure) {
        let store = self.provisioningStore
        var record: ProvisioningRecord
        do {
            record = try await store.load()
        } catch {
            throw ProvisioningStepFailure(
                step: .checkingHost,
                wireError: Self.operationWireError(for: error)
            )
        }
        if record.provisioned, request.recreateInstance != true {
            setProvisioningState(.complete)
            return
        }
        if request.recreateInstance == true {
            // Start Over after repeated failed first boots (§9.2): redo everything after the
            // image install; the instance is re-created so a corrupt userdata is dropped.
            record.failedFirstBoots = 0
            record.completedSteps = record.completedSteps.filter {
                $0 == ProvisioningStep.checkingHost.rawValue
                    || $0 == ProvisioningStep.installingImage.rawValue
            }
            try? await store.save(record)
        }
        func step(
            _ name: ProvisioningStep,
            _ record: ProvisioningRecord,
            _ body: () async throws -> Void
        ) async throws(ProvisioningStepFailure) -> ProvisioningRecord {
            guard !record.completedSteps.contains(name.rawValue) else { return record }
            do {
                try await body()
            } catch let failure as ProvisioningStepFailure {
                throw failure
            } catch {
                throw ProvisioningStepFailure(
                    step: name,
                    wireError: Self.operationWireError(for: error)
                )
            }
            var record = record
            record.completedSteps.append(name.rawValue)
            do {
                try await store.save(record)
            } catch {
                throw ProvisioningStepFailure(
                    step: name,
                    wireError: Self.operationWireError(for: error)
                )
            }
            return record
        }
        func fail(_ step: ProvisioningStep, _ error: some Error) -> ProvisioningStepFailure {
            ProvisioningStepFailure(
                step: step,
                wireError: Self.operationWireError(for: error)
            )
        }

        record = try await step(.checkingHost, record) {
            setProvisioningState(.checkingHost)
            // The daemon must own the instance lock to write the image and userdata; when a
            // developer CLI session (apkrun dev boot) holds it, provisioning cannot run.
            guard instanceLock != nil else {
                let failure = RuntimeFailure.instanceLocked(owner: .unknown)
                throw ProvisioningStepFailure(
                    step: .checkingHost,
                    wireError: Self.sessionWireError(for: .runtimeFailure(failure)),
                    stateError: Self.wireError(for: failure)
                )
            }
            let check = HostRequirementsCheck(
                probe: SystemHostProbe(),
                dataRoot: paths.dataRoot,
                requiredFreeBytes: await requiredFreeBytesForSetup(request: request, files: files)
            )
            let unmet = await check.unmetRequirements()
            guard unmet.isEmpty else {
                let failure = RuntimeFailure.hostRequirementsNotMet(unmet)
                throw ProvisioningStepFailure(
                    step: .checkingHost,
                    wireError: Self.sessionWireError(for: .runtimeFailure(failure)),
                    stateError: Self.wireError(for: failure)
                )
            }
        }
        record = try await step(.installingImage, record) {
            setProvisioningState(.installingImage(fraction: 0))
            switch request.image {
            case .directory(let bookmark):
                guard let url = Self.resolveImageBookmark(bookmark) else {
                    throw ProvisioningStepFailure(
                        step: .installingImage,
                        wireError: .runtime(
                            "malformedRequest",
                            message: "The image folder couldn't be opened."
                        )
                    )
                }
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let images =
                    imageStore
                    ?? ImageStore(
                        paths: paths,
                        trust: .standard(),
                        diagnostics: diagnostics ?? .live(paths: paths)
                    )
                imageStore = images
                do {
                    let installed = try await images.install(from: .directory(url))
                    image = installed
                    if instanceStore == nil, let diagnostics {
                        instanceStore = InstanceStore(paths: paths, diagnostics: diagnostics)
                    }
                } catch {
                    throw fail(.installingImage, error)
                }
                setProvisioningState(.installingImage(fraction: 1))
            case .feed, .archive, .unknown:
                // The release feed and .aar archives arrive with #59; setup needs a local image
                // bundle until then (apkrun setup --image <dir>).
                throw ProvisioningStepFailure(
                    step: .installingImage,
                    wireError: .runtime(
                        "serviceUnavailable",
                        message: "Image downloads are not available yet.",
                        remediation: "Install a local image bundle with `apkrun setup --image <folder>`."
                    )
                )
            }
        }
        record = try await step(.creatingInstance, record) {
            setProvisioningState(.creatingInstance)
            guard let image, let instanceStore else {
                throw fail(.creatingInstance, RuntimeHostError.image(.noCurrentImage))
            }
            var sizing = InstanceSizing.default
            let physical = await SystemHostProbe().physicalMemoryBytes()
            // NFR-RES-01: the VM's memory stays at or under half of physical memory.
            sizing.memoryBytes = min(sizing.memoryBytes, physical / 2)
            do {
                if try await instanceStore.load(image: image) == nil {
                    _ = try await instanceStore.provision(image: image, sizing: sizing)
                }
            } catch {
                throw fail(.creatingInstance, error)
            }
        }
        record = try await step(.firstBoot, record) {
            setProvisioningState(.firstBoot(.kernel, fraction: 0))
            let bootSupervisor: RuntimeSupervisor
            do {
                bootSupervisor = try supervisorInstance()
            } catch {
                throw fail(.firstBoot, error)
            }
            do {
                try await bootSupervisor.ensureReady(.user)
            } catch {
                throw fail(.firstBoot, error)
            }
        }
        record = try await step(.installingAgents, record) {
            setProvisioningState(.installingAgents)
            // The supervisor installs and launches the Guest Agent during ensureReady; nothing
            // remains here beyond marking the step for resume.
        }
        record = try await step(.verifying, record) {
            setProvisioningState(.verifying)
            let bootSupervisor: RuntimeSupervisor
            do {
                bootSupervisor = try supervisorInstance()
            } catch {
                throw fail(.verifying, error)
            }
            // After a daemon restart the recorded .firstBoot step is skipped even though
            // Android is not running; finish the boot here instead of failing.
            if await bootSupervisor.state != .ready {
                do {
                    try await bootSupervisor.ensureReady(.user)
                } catch {
                    throw fail(.verifying, error)
                }
            }
        }
        if let image, let instanceStore,
            let instance = try? await instanceStore.load(image: image)
        {
            record.userdataGeneration = instance.userdataGeneration
        }
        record.provisioned = true
        record.lastRuntimeVersion = buildInfo.marketingVersion
        record.lastRuntimeBuild = "\(buildInfo.buildNumber)"
        do {
            try await store.save(record)
        } catch {
            throw ProvisioningStepFailure(
                step: .verifying,
                wireError: Self.operationWireError(for: error)
            )
        }
        // Provisioning verified that Android boots and the agents are up, so any degraded
        // startup (e.g. a missing image recorded before setup ran) is obsolete.
        startupFailure = nil
        hostState = "running"
        setProvisioningState(.complete)
    }

    /// Deletes Android userdata and re-provisions (runtime-daemon.md §9.5).
    private func performResetAndroid(
        _ request: ResetAndroidRequest,
        operationID: WireOperationID
    ) async throws {
        guard instanceLock != nil else {
            throw RuntimeHostError.runtimeFailure(.instanceLocked(owner: .unknown))
        }
        guard let image, let instanceStore else {
            throw RuntimeHostError.image(.noCurrentImage)
        }
        // Reject new starts and package mutations for the whole reset, then let in-flight work
        // finish before the disks are erased.
        isRuntimeResetting = true
        defer { isRuntimeResetting = false }
        if let runtimeStartTask {
            _ = await runtimeStartTask.value
        }
        // A background reinstall must finish before the disks are erased: an install
        // landing after markForUserdataReset would flip a package back to `.installed`.
        if let reconcileTask {
            _ = await reconcileTask.value
        }
        await waitForPackageMutations()
        await supervisor?.stop(reason: .reset)
        await packageQueryService?.detachRuntime()
        headlessSessionService = nil
        if request.keepBackup {
            _ = try await instanceStore.createRecoveryPoint(image: image)
        }
        let instance = try await instanceStore.resetAndroid(
            image: image,
            sizing: .default
        )
        var record = try await provisioningStore.load()
        record.userdataGeneration = instance.userdataGeneration
        try await provisioningStore.save(record)
        // Mark every managed package as needing a reinstall on the new generation first: the
        // records must reflect the erase even when the reinstall cannot run yet — e.g. in a
        // build without the development Guest Agent (§9.5).
        let service = packageQueryServiceInstance()
        try await service.open()
        let marked = try await service.markForUserdataReset()
        pendingReinstallIDs = Set(marked)
        let bootSupervisor = try supervisorInstance()
        try await bootSupervisor.ensureReady(.user)
        // Reinstall the marked packages from their retained artifacts under the store's
        // operation assertion. When the runtime cannot attach, the marks are left for
        // reconcileManagedReinstalls() on a later boot.
        do {
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
        } catch {
            logger?.warning(
                "Reset Android: \(marked.count, .public) managed package(s) stay marked for reinstall until the runtime can attach."
            )
            setProvisioningState(.complete)
            return
        }
        for packageID in marked {
            do {
                try await reinstallManagedPackage(
                    packageID: packageID,
                    service: service
                )
                pendingReinstallIDs.remove(packageID)
            } catch {
                logger?.warning(
                    "Reinstall after Reset Android failed for \(packageID.rawValue, .public)"
                )
            }
        }
        setProvisioningState(.complete)
    }

    /// Retries managed packages still marked `needsReinstall` after a userdata reset or an
    /// earlier failed reinstall (§9.5). Called after a successful boot; failures only keep the
    /// mark for a later attempt.
    private func reconcileManagedReinstalls() async {
        let service = packageQueryService ?? packageQueryServiceInstance()
        do {
            try await service.open()
            let pending = try await service.pendingReinstalls()
            pendingReinstallIDs = Set(pending)
            guard !pending.isEmpty else { return }
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
            for packageID in pending {
                do {
                    try await reinstallManagedPackage(packageID: packageID, service: service)
                    pendingReinstallIDs.remove(packageID)
                } catch {
                    logger?.warning(
                        "Reinstall reconcile failed for \(packageID.rawValue, .public)"
                    )
                }
            }
        } catch {
            logger?.warning("Managed-package reinstall reconcile failed")
        }
    }

    /// Reinstalls a managed package from its retained `current/` artifacts
    /// (package-store.md §9.2). Returns the install result so callers that
    /// run a user-visible repair can publish the change; the silent §9.2
    /// reconcile ignores it.
    @discardableResult
    private func reinstallManagedPackage(
        packageID: RuntimePackageID,
        service: EmbeddedPackageService
    ) async throws -> RuntimePackageInstallResult? {
        let current = try await service.artifactCurrentDirectory(for: packageID)
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: current.path)
                .filter({ $0.hasSuffix(".apk") }).sorted(),
            !names.isEmpty
        else {
            return nil
        }
        var handles: [FileHandle] = []
        var sourceFiles: [RuntimeImportSourceFile] = []
        for (index, name) in names.enumerated() {
            guard
                let handle = try? FileHandle(
                    forReadingFrom: current.appendingPathComponent(name)
                )
            else {
                for handle in handles {
                    try? handle.close()
                }
                return nil
            }
            handles.append(handle)
            sourceFiles.append(RuntimeImportSourceFile(fileIndex: index, name: name))
        }
        defer {
            for handle in handles {
                try? handle.close()
            }
        }
        let preview = try await service.importPackage(
            RuntimeImportPackageRequest(files: sourceFiles, origin: .cli),
            files: handles
        )
        // `requiresReinstallMark` is checked inside the store's mutation lock: an
        // `uninstall --forget` or uninstall committed between the reconcile's
        // snapshot and the install removes the mark or the record, and without
        // the guard the retained APKs would resurrect the app.
        return try await service.installImportedWithChange(
            RuntimeInstallImportedRequest(ticket: preview.ticket),
            requiresReinstallMark: true
        )
    }

    /// The free space §9.1 requires: the expanded image plus userdata and a 10 GiB margin.
    /// A directory source is measured on disk; an unknown source assumes the feed's typical size.
    private func requiredFreeBytesForSetup(
        request: SetupRequest,
        files: [FileHandle]
    ) async -> Int64 {
        var imageBytes: Int64 = 12 * 1024 * 1024 * 1024
        if case .directory(let bookmark) = request.image,
            let url = Self.resolveImageBookmark(bookmark),
            let allocated = directoryAllocatedBytes(at: url)
        {
            imageBytes = allocated
        }
        return HostRequirementsCheck.requiredFreeBytes(
            expandedImageBytes: imageBytes,
            userdataBytes: Int64(InstanceSizing.default.userdataBytes)
        )
    }

    /// Resolves an image-folder bookmark the client sent. Sandbox-less builds create plain
    /// bookmarks, so a scoped resolution failure falls back to a plain resolve.
    static func resolveImageBookmark(_ bookmark: Data) -> URL? {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            bookmarkDataIsStale: &stale
        ) {
            return url
        }
        return try? URL(
            resolvingBookmarkData: bookmark,
            bookmarkDataIsStale: &stale
        )
    }

    /// The total allocated size of a directory tree, or nil when it cannot be measured.
    private func directoryAllocatedBytes(at url: URL) -> Int64? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]
            )
        else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(
                forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]
            ),
                values.isRegularFile == true
            {
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    /// The runtime supervisor, creating it when provisioning installed the first image after
    /// the daemon started without one.
    private func supervisorInstance() throws -> RuntimeSupervisor {
        if let supervisor {
            return supervisor
        }
        guard let image, let instanceStore, let diagnostics else {
            throw RuntimeHostError.image(.noCurrentImage)
        }
        let guestDirectory = DevGuestAgentLocation.directory(
            guestDir: nil,
            environment: environment,
            executable: executableURL
        )
        let bundle = try GuestAgentBundle.load(directory: guestDirectory)
        let runtimeSupervisor = RuntimeSupervisor(
            image: image,
            instanceStore: instanceStore,
            options: BootOptions(
                gpuProfile: .drmVirgl,
                developerMode: buildInfo.configuration == .debug,
                captureLogcat: false
            ),
            diagnostics: diagnostics,
            guestAgentBundle: bundle,
            guestAgentTimeout: .seconds(30)
        )
        supervisor = runtimeSupervisor
        observeSupervisorEvents(from: runtimeSupervisor)
        return runtimeSupervisor
    }

    func packageQueryServiceInstance() -> EmbeddedPackageService {
        if let packageQueryService {
            return packageQueryService
        }
        let service = EmbeddedPackageService(paths: paths)
        Task { [weak self] in
            await service.setIconChangeHandler { [weak self] packageID in
                guard let wireID = RuntimePackageID(rawValue: packageID.rawValue) else { return }
                self?.eventHub.publishPackageChange(.iconChanged(wireID))
            }
        }
        packageQueryService = service
        return service
    }

    func attachPackageQueriesIfRuntimeIsReady(
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

    /// The dev Store Agent channel for update constraint checks
    /// (update-system.md §7.1 GU5); `nil` without an attached runtime.
    func storeAccessForUpdateConstraints() -> DevelopmentStoreRuntimeAccess? {
        guard let supervisor, let image, let instanceStore,
            let adbExecutable = try? AdbClient.resolveExecutable(environment: environment)
        else { return nil }
        return DevelopmentStoreRuntimeAccess(
            supervisor: supervisor,
            adbExecutable: adbExecutable,
            instanceStore: instanceStore,
            image: image,
            logSink: diagnostics?.logSink,
            startRuntimeIfNeeded: false
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

    static func sessionWireError(for error: RuntimeHostError) -> RuntimeWireError {
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
        case .stopping(_): "stopping"
        case .failed: "failed"
        }
    }
}
