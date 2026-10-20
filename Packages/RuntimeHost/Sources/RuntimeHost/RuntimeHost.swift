import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeAPI
import RuntimeCore

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
    private let paths: APKRunPaths
    private let buildInfo: BuildInfo
    private let environment: [String: String]
    private let executableURL: URL
    private let uncleanExitRecoveryOverride: (any DaemonUncleanExitRecovering)?
    private var diagnostics: DiagnosticsContext?
    private var logger: APKLogger?
    private var instanceLock: InstanceLock?
    private var stateStore: DaemonStateStore?
    private var startupAssessment: DaemonStartupAssessment?
    private var image: InstalledImage?
    private var instanceStore: InstanceStore?
    private var supervisor: RuntimeSupervisor?
    private var packageQueryService: EmbeddedPackageService?
    private var headlessSessionService: (any RuntimeSessionService)?
    private var runtimeSessionGeneration: UInt64 = 0
    private var bootProgressEstimator: BootProgressEstimator?
    private var bootStartedAt: ContinuousClock.Instant?
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
    private var activePackageInstalls = 0
    private var runtimeStartTask: Task<Result<Void, RuntimeHostError>, Never>?
    private var isRuntimeStopping = false
    private var isRuntimeResetting = false
    private var isRuntimeRestarting = false
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var packageInstallWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private var trackedOperations: [WireOperationID: RuntimeTrackedOperation] = [:]

    /// Creates a daemon host for the current user.
    public init(
        paths: APKRunPaths = APKRunPaths(),
        buildInfo: BuildInfo = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "apkrund"),
        uncleanExitRecovery: (any DaemonUncleanExitRecovering)? = nil
    ) {
        self.paths = paths
        self.buildInfo = buildInfo
        self.environment = environment
        self.executableURL = executableURL
        uncleanExitRecoveryOverride = uncleanExitRecovery
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
                supervisor = RuntimeSupervisor(
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

    private func startRuntimeBody(reason: StartReason) async throws(RuntimeHostError) {
        try await waitForStartupCompletion()
        try beginLifecycleOperation()
        defer { finishLifecycleOperation() }

        if let runtimeStartTask {
            try await runtimeStartTask.value.get()
            return
        }

        let task = Task { [weak self] () -> Result<Void, RuntimeHostError> in
            guard let self else { return .failure(.notStarted) }
            do {
                try await self.performRuntimeStart(reason: reason)
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

    private func performRuntimeStart(reason: StartReason) async throws(RuntimeHostError) {
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
        guard !isShuttingDown else {
            throw .shuttingDown
        }
        bootProgressEstimator = BootProgressEstimator(
            bootKind: instance.firstBootSettingsApplied ? "cold" : "firstBoot",
            history: progressHistory()
        )
        bootStartedAt = ContinuousClock.now
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
            activePackageInstalls == 0
        else {
            throw .invalidTransition
        }
        isRuntimeStopping = true
        defer { isRuntimeStopping = false }
        try await stopRuntimeBody()
    }

    /// Restarts Android under one reserved lifecycle transition.
    public func restartRuntime(reason: StartReason) async throws(RuntimeHostError) {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting, activeRuntimeStarts == 0,
            activePackageInstalls == 0
        else {
            throw .invalidTransition
        }
        isRuntimeRestarting = true
        defer { isRuntimeRestarting = false }
        try await stopRuntimeBody()
        try await startRuntimeBody(reason: reason)
    }

    private func stopRuntimeBody() async throws(RuntimeHostError) {
        try await waitForStartupCompletion()
        try beginLifecycleOperation()
        defer { finishLifecycleOperation() }
        runtimeSessionGeneration &+= 1
        if let service = headlessSessionService as? DaemonHeadlessSessionService {
            await service.shutdown()
        }
        await supervisor?.stop()
        await packageQueryService?.detachRuntime()
        headlessSessionService = nil
    }

    /// Clears the automatic boot-loop guard without starting Android or deleting user data.
    public func resetRuntime() async throws(RuntimeHostError) -> RuntimeHostStatus {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting, activeRuntimeStarts == 0,
            activePackageInstalls == 0
        else {
            throw .invalidTransition
        }
        isRuntimeResetting = true
        defer { isRuntimeResetting = false }
        try await waitForStartupCompletion()
        try beginLifecycleOperation()
        defer { finishLifecycleOperation() }

        if await supervisor?.state == .stopping {
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
        guard headlessLaunchHookIsEnabled else {
            throw Self.launchUnavailableError
        }
        do {
            try await startRuntime(reason: .automatic)
        } catch {
            throw Self.sessionWireError(for: error)
        }
        let service = try await makeHeadlessSessionService()
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
        do {
            try beginPackageInstall()
        } catch {
            throw Self.sessionWireError(for: error)
        }
        defer { finishPackageInstall() }

        return try await performInstallImported(request, clientKind: nil, operationID: nil)
    }

    /// Begins a daemon-owned install and returns its handle before Android starts or installs the APK.
    ///
    /// The lifecycle reservation and operation record are created synchronously before the handle
    /// is returned. A repeated request with the same ID and payload joins the existing operation.
    func beginInstallImported(
        _ request: RuntimeInstallImportedRequest,
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
            guard existing.handle.kind == .install, existing.requestPayload == requestPayload else {
                throw .runtime(
                    "malformedRequest",
                    message: "The operation ID is already being used for a different request."
                )
            }
            return existing.handle
        }

        do {
            try beginPackageInstall()
        } catch {
            throw Self.sessionWireError(for: error)
        }

        let handle = OperationHandle(operationID: requestedID, kind: .install)
        let snapshot = OperationSnapshot(
            operationID: requestedID,
            kind: .install,
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
        let task = Task { [weak self] in
            guard let self else { return }
            if let diagnosticsID = DiagnosticsCore.OperationID(wire: requestedID.wireValue) {
                let context = OperationContext(operationID: diagnosticsID)
                await OperationContext.$current.withValue(context) {
                    await self.runInstallOperation(
                        request,
                        operationID: requestedID,
                        clientKind: clientKind
                    )
                }
            } else {
                await self.runInstallOperation(request, operationID: requestedID, clientKind: clientKind)
            }
        }
        trackedOperations[requestedID]?.task = task
        return handle
    }

    /// Returns running operations and up to fifty recently finished operations.
    func listOperations() -> [OperationSnapshot] {
        trackedOperations.values
            .map(\.snapshot)
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Returns a retained operation snapshot.
    func operationStatus(_ operationID: WireOperationID) throws(RuntimeWireError) -> OperationSnapshot {
        guard let operation = trackedOperations[operationID] else {
            throw Self.operationNotFoundError
        }
        return operation.snapshot
    }

    /// Requests cancellation before the PackageStore guest-install phase begins.
    func cancelOperation(_ operationID: WireOperationID) throws(RuntimeWireError) -> CancelReply {
        guard let operation = trackedOperations[operationID] else {
            throw Self.operationNotFoundError
        }
        if let result = operation.snapshot.result {
            return .alreadyFinished(result)
        }
        guard operation.isCancellable else {
            return .notCancellable(reason: "Android package installation has started and will continue.")
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
        operationID: WireOperationID,
        clientKind: RuntimeClientKind
    ) async {
        defer { finishPackageInstall() }
        do {
            let result = try await performInstallImported(
                request,
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

    private func performInstallImported(
        _ request: RuntimeInstallImportedRequest,
        clientKind: RuntimeClientKind?,
        operationID: WireOperationID?
    ) async throws(RuntimeWireError) -> RuntimePackageSummary {
        let service = packageQueryServiceInstance()
        try await service.open()
        do {
            try Task.checkCancellation()
        } catch {
            throw Self.cancelledOperationError
        }

        do {
            try await startRuntime(reason: clientKind == .cli ? .cli : .user)
        } catch {
            throw Self.sessionWireError(for: error)
        }

        try await attachPackageQueriesIfRuntimeIsReady(to: service)
        if let operationID {
            guard !Task.isCancelled else {
                throw Self.cancelledOperationError
            }
            // PackageStore currently makes the guest install a single transaction call. From this
            // point it reconciles ambiguous guest results and must run to a terminal journal state.
            setInstallNotCancellable(operationID)
        }
        return try await service.installImported(request)
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
            message: "APKRun couldn't complete the package installation."
        )
    }

    private func setInstallNotCancellable(_ operationID: WireOperationID) {
        guard var operation = trackedOperations[operationID], operation.snapshot.result == nil else {
            return
        }
        operation.isCancellable = false
        operation.snapshot = OperationSnapshot(
            operationID: operation.snapshot.operationID,
            parent: operation.snapshot.parent,
            kind: operation.snapshot.kind,
            packageID: operation.snapshot.packageID,
            clientKind: operation.snapshot.clientKind,
            startedAt: operation.snapshot.startedAt,
            progress: OperationProgress(
                stage: "installing",
                message: "Installing the Android package…"
            )
        )
        trackedOperations[operationID] = operation
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
            clientKind: operation.snapshot.clientKind,
            startedAt: operation.snapshot.startedAt,
            progress: operation.snapshot.progress,
            result: result,
            finishedAt: Date()
        )
        trackedOperations[operationID] = operation
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
        let runtimeStateValue = await supervisor?.state
        let guestAgentStatus = await supervisor?.guestAgentStatusSnapshot()
        let runtimeState: String
        let bootProgress: Double?
        if let runtimeStateValue {
            runtimeState = Self.describe(runtimeStateValue)
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
        } else {
            runtimeState = "stopped"
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
        guard hasStarted else {
            hostState = "stopped"
            completeShutdown()
            return
        }
        if let service = headlessSessionService as? DaemonHeadlessSessionService {
            await service.shutdown()
        }
        headlessSessionService = nil
        await waitForPackageInstalls()
        // Mark an in-flight VM start for cancellation before waiting for any storage work to finish.
        await supervisor?.stop()
        await waitForLifecycleOperations()
        // A start that was already inside RuntimeSupervisor may have finished its cancellation path
        // while this actor was waiting. Stop once more before recording a clean process exit.
        await supervisor?.stop()
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

    private func beginLifecycleOperation() throws(RuntimeHostError) {
        guard hasStarted else {
            throw .notStarted
        }
        guard !isShuttingDown else {
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

    private func beginPackageInstall() throws(RuntimeHostError) {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting else {
            throw .invalidTransition
        }
        try beginLifecycleOperation()
        activePackageInstalls += 1
    }

    private func finishPackageInstall() {
        activePackageInstalls -= 1
        if activePackageInstalls == 0 {
            let waiters = packageInstallWaiters
            packageInstallWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        finishLifecycleOperation()
    }

    private func waitForPackageInstalls() async {
        guard activePackageInstalls > 0 else { return }
        await withCheckedContinuation { continuation in
            packageInstallWaiters.append(continuation)
        }
    }

    private func waitForLifecycleOperations() async {
        guard activeLifecycleOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(continuation)
        }
    }

    private func waitForStartupCompletion() async throws(RuntimeHostError) {
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
        guard !isShuttingDown else {
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
        case .stopping: "stopping"
        case .failed: "failed"
        }
    }
}
