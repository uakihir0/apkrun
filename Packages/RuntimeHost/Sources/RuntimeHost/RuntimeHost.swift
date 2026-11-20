import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeAPI
import RuntimeCore
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

private struct RuntimeTrackedOperation {
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

    private let paths: APKRunPaths
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
    private var logger: APKLogger?
    private var instanceLock: InstanceLock?
    private var stateStore: DaemonStateStore?
    private var startupAssessment: DaemonStartupAssessment?
    private var image: InstalledImage?
    private var instanceStore: InstanceStore?
    private var supervisor: RuntimeSupervisor?
    private var supervisorEventsTask: Task<Void, Never>?
    private var packageQueryService: EmbeddedPackageService?
    private var wrapperRegistry: WrapperRegistry?
    private var wrapperRegistryLoadTask: Task<WrapperRegistry, Never>?
    private var wrapperHealthChecksRegistered = false
    /// Package IDs with a `wrapperCreate` operation in flight.
    private var wrapperCreationsInFlight: Set<String> = []
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

        // Load the wrapper registry and recover pending/refreshing entries at
        // daemon start (wrapper.md §6.2), independent of the first verify call.
        Task { _ = await self.wrapperRegistryInstance() }

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
        try requirePackageLaunchAllowed(request.packageID)
        let service = try await makeHeadlessSessionService()
        try requirePackageLaunchAllowed(request.packageID)
        return try await service.launch(request)
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
            sink: diagnostics?.logSink
        )
        do {
            let verification = try await validator.verify(
                url: request.bundleURL, deep: request.deep)
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
                bundledVersion: nil
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

        let iconSource: WrapperIconSource
        switch request.icon {
        case .custom:
            let data = icon.flatMap { try? $0.readToEnd() }
            guard let data, !data.isEmpty else {
                throw Self.wrapperWireError(for: .customIconInvalid(.unreadable))
            }
            iconSource = .preview(data)
        case .android, .none:
            iconSource = .placeholder
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

        guard let entry = await registry.entry(bundleID: generated.bundleID) else {
            throw .runtime("internal", message: "APKRun couldn't register the Mac app.")
        }
        let summary = Self.wrapperSummary(for: entry, packageID: request.packageID)
        eventHub.publishWrapperChange(.created(summary), operationID: operationID)
        return WrapperInfo(
            summary: summary,
            fileName: entry.fileName,
            customization: WrapperCustomizationWire(
                displayName: entry.customization.displayName,
                customIcon: entry.customization.iconFile != nil
            ),
            signer: .adHoc,
            cdhash: generated.cdhash,
            launcherAPI: Self.launcherAPIVersion(entry.launcherAPI) ?? APIVersion(major: 1, minor: 0),
            formatVersion: entry.formatVersion,
            iconDigest: entry.iconDigest.flatMap { RuntimeSHA256Digest(rawValue: "sha256:\($0)") },
            lastValidatedAt: entry.lastValidatedAt,
            warnings: []
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
    private func wrapperRegistryInstance() async -> WrapperRegistry {
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
            if let build = launcherBuild() {
                try? await checks.register(
                    WrapperHealthChecks.template(executableURL: build.executableURL))
            }
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
            remediation: remediation
        )
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

    private func beginPackageMutation() throws(RuntimeHostError) {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting else {
            throw .invalidTransition
        }
        try beginLifecycleOperation()
        activePackageMutations += 1
    }

    private func finishPackageMutation() {
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
            logSink: diagnostics?.logSink
        )
        headlessSessionService = service
        return service
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
                var stale = false
                guard
                    let url = try? URL(
                        resolvingBookmarkData: bookmark,
                        options: .withSecurityScope,
                        bookmarkDataIsStale: &stale
                    )
                else {
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
            guard let supervisor, await supervisor.state == .ready else {
                throw ProvisioningStepFailure(
                    step: .verifying,
                    wireError: .runtime(
                        "serviceUnavailable",
                        message: "Android did not finish starting.",
                        remediation: "Run setup again."
                    )
                )
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
        setProvisioningState(.complete)
    }

    /// Deletes Android userdata and re-provisions (runtime-daemon.md §9.5).
    private func performResetAndroid(
        _ request: ResetAndroidRequest,
        operationID: WireOperationID
    ) async throws {
        guard let image, let instanceStore else {
            throw RuntimeHostError.image(.noCurrentImage)
        }
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
        let bootSupervisor = try supervisorInstance()
        try await bootSupervisor.ensureReady(.user)
        // Mark every managed package as needing a reinstall on the new generation, then reinstall
        // it from its retained artifact under the store's operation assertion (§9.5).
        let service = packageQueryServiceInstance()
        try await service.open()
        try await attachPackageQueriesIfRuntimeIsReady(to: service)
        let marked = try await service.markForUserdataReset()
        for packageID in marked {
            do {
                try await reinstallManagedPackage(
                    packageID: packageID,
                    service: service
                )
            } catch {
                logger?.warning(
                    "Reinstall after Reset Android failed for \(packageID.rawValue, .public)"
                )
            }
        }
        setProvisioningState(.complete)
    }

    /// Reinstalls one managed package from `Packages/<id>/current/` after a userdata reset.
    private func reinstallManagedPackage(
        packageID: RuntimePackageID,
        service: EmbeddedPackageService
    ) async throws {
        let current = paths.packageCurrentDirectory(packageID: packageID.rawValue)
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: current.path)
                .filter({ $0.hasSuffix(".apk") }).sorted(),
            !names.isEmpty
        else {
            return
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
                return
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
        _ = try await service.installImportedWithChange(
            RuntimeInstallImportedRequest(ticket: preview.ticket)
        )
    }

    /// The free space §9.1 requires: the expanded image plus userdata and a 10 GiB margin.
    /// A directory source is measured on disk; an unknown source assumes the feed's typical size.
    private func requiredFreeBytesForSetup(
        request: SetupRequest,
        files: [FileHandle]
    ) async -> Int64 {
        var imageBytes: Int64 = 12 * 1024 * 1024 * 1024
        var stale = false
        if case .directory(let bookmark) = request.image,
            let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                bookmarkDataIsStale: &stale
            ),
            let allocated = directoryAllocatedBytes(at: url)
        {
            imageBytes = allocated
        }
        return HostRequirementsCheck.requiredFreeBytes(
            expandedImageBytes: imageBytes,
            userdataBytes: Int64(InstanceSizing.default.userdataBytes)
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
        case .stopping(_): "stopping"
        case .failed: "failed"
        }
    }
}
