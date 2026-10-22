import Darwin
import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeAPI
import RuntimeCore

typealias WireOperationID = RuntimeAPI.OperationID

struct RuntimeExecutionSettings: Equatable, Sendable {
    let bootTimeouts: BootTimeouts
    let maxDisplaySessions: Int

    static let `default` = Self(bootTimeouts: .standard, maxDisplaySessions: 8)

    init(bootTimeouts: BootTimeouts, maxDisplaySessions: Int) {
        self.bootTimeouts = bootTimeouts
        self.maxDisplaySessions = maxDisplaySessions
    }

    init(snapshot: ConfigurationSnapshot) {
        func integer(_ key: String, fallback: Int) -> Int {
            guard let entry = snapshot.entries.first(where: { $0.key == key }),
                case .integer(let value) = entry.value,
                let resolved = Int(exactly: value)
            else {
                return fallback
            }
            return resolved
        }

        let standard = BootTimeouts.standard
        bootTimeouts = BootTimeouts(
            whole: .seconds(integer("runtime.bootTimeoutSeconds", fallback: 180)),
            firstBoot: .seconds(integer("runtime.firstBootTimeoutSeconds", fallback: 900)),
            stall: standard.stall,
            firstBootStall: standard.firstBootStall
        )
        maxDisplaySessions = integer("display.maxSessions", fallback: 8)
    }
}

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
    /// The runtime has active sessions and the caller did not request a forced stop.
    case busy
    /// The Guest Agent bundle is missing or invalid.
    case guestAgentBundle(String)
    /// Runtime boot failed.
    case runtimeBoot(RuntimeBootFailure)
    /// The daemon lifecycle record could not be updated.
    case stateStore(DaemonStateStoreError)
}

enum RuntimeStopPolicy {
    static func transitionError(
        isStopping: Bool,
        isResetting: Bool,
        isRestarting: Bool,
        activeRuntimeStarts: Int,
        activePackageMutations: Int,
        hasActivePackageLaunches: Bool
    ) -> RuntimeHostError? {
        guard !isStopping, !isResetting, !isRestarting,
            activeRuntimeStarts == 0, activePackageMutations == 0, !hasActivePackageLaunches
        else {
            return .invalidTransition
        }
        return nil
    }

    static func sessionError(force: Bool, hasActiveSessions: Bool) -> RuntimeHostError? {
        !force && hasActiveSessions ? .busy : nil
    }
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
    private var diagnostics: DiagnosticsContext?
    private var logger: APKLogger?
    private var instanceLock: InstanceLock?
    private var stateStore: DaemonStateStore?
    private var globalSettingsStore: GlobalSettingsStore?
    private var startupAssessment: DaemonStartupAssessment?
    private var image: InstalledImage?
    private var instanceStore: InstanceStore?
    private var supervisor: RuntimeSupervisor?
    private var supervisorEventsTask: Task<Void, Never>?
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

        // Initialize the settings store before publishing so an early information request can read
        // it. Publish after steps 1–3 so the broker remains available during slower settings and
        // image recovery; requests serialize with the store actor's first load.
        let settingsStore = instanceLock == nil ? nil : GlobalSettingsStore(fileURL: paths.settingsFile)
        globalSettingsStore = settingsStore
        let listenerReadyAt = try publishListener()
        markDaemonReady(at: listenerReadyAt)

        // Startup step 4: load global settings. A newer schema stays untouched and leaves the
        // broker available for diagnostics and recovery.
        if let settingsStore {
            do {
                let result = try await settingsStore.load()
                for diagnostic in result.diagnostics {
                    switch diagnostic {
                    case .unknownKey(let key):
                        logger.warning("Ignoring unknown global setting \(key, .public)")
                    case .invalidValue(let key):
                        logger.warning("Ignoring invalid global setting \(key, .public)")
                    case .corruptFile:
                        logger.warning("The global settings file was invalid; defaults are in use")
                    case .migrated(let fromSchema):
                        logger.notice("Migrated global settings from schema \(fromSchema, .public)")
                    }
                }
            } catch {
                recordDegradedStartup(step: 4, code: "runtime.hostStartupFailed")
            }
        }

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
                let executionSettings: RuntimeExecutionSettings
                if let settingsStore, let snapshot = try? await settingsStore.snapshot() {
                    executionSettings = RuntimeExecutionSettings(snapshot: snapshot)
                } else {
                    executionSettings = .default
                }
                let runtimeSupervisor = RuntimeSupervisor(
                    image: image,
                    instanceStore: instanceStore,
                    options: BootOptions(
                        gpuProfile: .drmVirgl,
                        developerMode: buildInfo.configuration == .debug,
                        captureLogcat: false
                    ),
                    diagnostics: diagnostics,
                    timeouts: executionSettings.bootTimeouts,
                    maxDisplaySessions: executionSettings.maxDisplaySessions,
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
            let settings = try? await globalSettingsStore?.snapshot()
            if let existing = try await instanceStore.load(image: image) {
                let sizing = Self.instanceSizing(
                    from: settings,
                    preservingUserdataBytes: existing.sizing.userdataBytes
                )
                guard let sizing else {
                    throw Self.userdataCapacityFailure(at: paths.settingsFile)
                }
                instance = try await instanceStore.updateRuntimeSizing(
                    cpuCount: sizing.cpuCount,
                    memoryBytes: sizing.memoryBytes
                )
            } else {
                instance = try await instanceStore.provision(
                    image: image,
                    sizing: try Self.provisioningSizing(from: settings, settingsFile: paths.settingsFile)
                )
            }
        } catch let failure as ImageFailure {
            throw .image(failure)
        } catch {
            let underlying = error as NSError
            throw .image(
                .cloneFailed(
                    underlying: UnderlyingError(domain: underlying.domain, code: underlying.code)
                )
            )
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
    public func stopRuntime(force: Bool = false) async throws(RuntimeHostError) {
        if let error = RuntimeStopPolicy.transitionError(
            isStopping: isRuntimeStopping,
            isResetting: isRuntimeResetting,
            isRestarting: isRuntimeRestarting,
            activeRuntimeStarts: activeRuntimeStarts,
            activePackageMutations: activePackageMutations,
            hasActivePackageLaunches: packageActivityReservations.hasAnyActiveLaunches
        ) {
            throw error
        }
        isRuntimeStopping = true
        defer { isRuntimeStopping = false }
        let hasActiveSessions = force ? false : await hasActiveAppSessions()
        if let error = RuntimeStopPolicy.sessionError(
            force: force,
            hasActiveSessions: hasActiveSessions
        ) {
            throw error
        }
        try await stopRuntimeBody(reason: .user)
    }

    private func hasActiveAppSessions() async -> Bool {
        guard let service = headlessSessionService as? DaemonHeadlessSessionService else {
            return false
        }
        return !(await service.inventory()).sessions.isEmpty
    }

    /// Restarts Android under one reserved lifecycle transition.
    public func restartRuntime(reason: StartReason) async throws(RuntimeHostError) {
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting, activeRuntimeStarts == 0,
            activePackageMutations == 0, !packageActivityReservations.hasAnyActiveLaunches
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
            activePackageMutations == 0, !packageActivityReservations.hasAnyActiveLaunches
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
        guard !isRuntimeStopping, !isRuntimeResetting, !isRuntimeRestarting else {
            throw Self.sessionWireError(for: .invalidTransition)
        }
        do {
            try packageActivityReservations.beginLaunch(packageID: packageID.rawValue)
        } catch {
            throw Self.packageOperationInProgressError
        }
    }

    private func finishPackageLaunch(_ packageID: RuntimePackageID) {
        packageActivityReservations.finishLaunch(packageID: packageID.rawValue)
    }

    func logWrapperAuthorizationFailure(packageID: RuntimePackageID, operationID: UUID) {
        guard let diagnostics else { return }
        let logger = APKLogger(
            category: RuntimeLogCategory.xpc,
            sink: diagnostics.logSink,
            context: LogContext(operationID: operationID.uuidString, packageID: packageID.rawValue)
        )
        logger.warning("Wrapper package authorization denied", errorCode: "runtime.notAuthorized")
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
            guestAgentProtocolVersion: guestAgentStatus?.protocolVersion?.description
        )
    }

    /// Returns runtime state, configured sizing, and any requested diagnostics without starting Android.
    public func runtimeInfo(_ request: RuntimeInfoRequest = RuntimeInfoRequest()) async -> RuntimeInfo {
        let currentStatus = await status()
        let settings = try? await globalSettingsStore?.snapshot()
        let sizing = RuntimeSizing(
            cpuCount: Self.integerSetting("runtime.cpuCount", in: settings) ?? 4,
            memoryGiB: Self.integerSetting("runtime.memoryGiB", in: settings) ?? 4,
            userdataGiB: settings.flatMap { Self.integerSetting("runtime.userdataGiB", in: $0) }
        )
        let resources: ResourceUsage?
        if request.resources {
            let footprint = Self.currentPhysicalFootprintBytes()
            resources = footprint.map { ResourceUsage(daemonPhysicalFootprintBytes: $0) }
        } else {
            resources = nil
        }
        let displays: [RuntimeDisplaySlotSnapshot]?
        if request.displays {
            displays = await displaySnapshots(runtimeIsReady: currentStatus.runtimeState == "ready")
        } else {
            displays = nil
        }
        return RuntimeInfo(
            status: currentStatus,
            sizing: sizing,
            displayPoolSize: 16,
            resources: resources,
            displays: displays
        )
    }

    /// Lists live daemon-owned app sessions with their display and window geometry.
    public func listSessions() async -> [SessionSummary] {
        guard let service = headlessSessionService as? DaemonHeadlessSessionService else {
            return []
        }
        let inventory = await service.inventory()
        let packageService = packageQueryServiceInstance()
        var summaries: [SessionSummary] = []
        summaries.reserveCapacity(inventory.sessions.count)
        for session in inventory.sessions {
            guard case .app(let sessionID) = session.id,
                let packageID = RuntimePackageID(rawValue: session.packageID)
            else {
                continue
            }
            let details = try? await packageService.packageInfo(RuntimePackageRequest(packageID: packageID))
            let lease = inventory.leases[sessionID]
            let phase: RuntimeSessionPhase
            switch session.state {
            case .requested:
                phase = .starting
            case .waitingForRuntime:
                phase = .booting
            case .acquiringDisplay:
                phase = .acquiringDisplay
            case .launching:
                phase = .launching
            case .running, .backgrounded:
                phase = .running
            case .closing:
                phase = .closing
            case .ended:
                phase = .ended
            }
            let pointSize: CGSize?
            if let mode = lease?.mode, mode.renderScale.isFinite, mode.renderScale > 0 {
                pointSize = CGSize(
                    width: Double(mode.pixelSize.width) / mode.renderScale,
                    height: Double(mode.pixelSize.height) / mode.renderScale
                )
            } else {
                pointSize = nil
            }
            summaries.append(
                SessionSummary(
                    sessionID: sessionID,
                    packageID: packageID,
                    displayName: details?.summary.displayName ?? session.packageID,
                    state: phase,
                    displayID: lease.flatMap { DisplayID(rawValue: $0.leaseID.uuidString.lowercased()) },
                    clientKind: .cli,
                    openedAt: session.openedAt,
                    windowMode: session.displayID == 0 ? .primaryDisplayCompatibility : .secondaryDisplay,
                    recording: false,
                    pointSize: pointSize
                )
            )
        }
        return summaries
    }

    /// Reads the complete resolved global configuration.
    public func configuration() async throws(RuntimeWireError) -> ConfigurationSnapshot {
        guard let globalSettingsStore else {
            throw Self.configurationStartupError
        }
        do {
            return try await globalSettingsStore.snapshot()
        } catch {
            throw Self.configurationWireError(for: error)
        }
    }

    /// Validates and persists global configuration before publishing its change event.
    public func updateConfiguration(_ patch: ConfigurationPatch) async throws(RuntimeWireError)
        -> ConfigurationSnapshot
    {
        guard let globalSettingsStore else {
            throw Self.configurationStartupError
        }
        do {
            let result = try await globalSettingsStore.update(patch)
            if !result.changedKeys.isEmpty, let supervisor {
                let executionSettings = RuntimeExecutionSettings(snapshot: result.snapshot)
                await supervisor.applyRuntimeSettings(
                    timeouts: executionSettings.bootTimeouts,
                    maxDisplaySessions: executionSettings.maxDisplaySessions
                )
            }
            if !result.changedKeys.isEmpty {
                eventHub.publishRuntimeChange(.configurationChanged(keys: result.changedKeys))
            }
            return result.snapshot
        } catch {
            throw Self.configurationWireError(for: error)
        }
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
    private static let configurationStartupError = RuntimeWireError.runtime(
        "hostStartupFailed",
        message: "APKRun couldn't load global settings.",
        remediation: "Run apkrun runtime status for details, then follow the reported error's instructions."
    )

    private func displaySnapshots(runtimeIsReady: Bool) async -> [RuntimeDisplaySlotSnapshot] {
        let slots: [RuntimeCore.DisplaySlotSnapshot]
        let leases: [UUID: DisplayLease]
        if let service = headlessSessionService as? DaemonHeadlessSessionService {
            let inventory = await service.inventory()
            slots = inventory.slots
            leases = inventory.leases
        } else if runtimeIsReady, let displayPool = await supervisor?.makeDisplayPool() {
            slots = await displayPool.snapshot()
            leases = [:]
        } else {
            slots = []
            leases = [:]
        }

        var result = [
            RuntimeDisplaySlotSnapshot(
                slot: 0,
                state: runtimeIsReady ? .reserved : .free,
                androidDisplayID: runtimeIsReady ? 0 : nil
            )
        ]
        result.reserveCapacity(16)
        for slot in slots {
            let ownerID: UUID?
            switch slot.state {
            case .attaching(let owner), .allocated(let owner), .releasing(let owner):
                ownerID = Self.appSessionUUID(for: owner)
            case .free, .faulted:
                ownerID = nil
            }
            let lease = ownerID.flatMap { leases[$0] }
            let pixelSize = slot.mode.map {
                RuntimeAPI.PixelSize(width: $0.pixelSize.width, height: $0.pixelSize.height)
            }
            result.append(
                RuntimeDisplaySlotSnapshot(
                    slot: slot.scanout,
                    state: Self.wireDisplayState(for: slot.state),
                    displayID: lease.flatMap { DisplayID(rawValue: $0.leaseID.uuidString.lowercased()) },
                    androidDisplayID: slot.androidDisplayID,
                    pixelSize: pixelSize,
                    densityDpi: slot.mode?.densityDpi
                )
            )
        }
        return result.sorted { $0.slot < $1.slot }
    }

    private static func integerSetting(_ key: String, in snapshot: ConfigurationSnapshot?) -> Int? {
        guard let entry = snapshot?.entries.first(where: { $0.key == key }),
            case .integer(let value) = entry.value
        else {
            return nil
        }
        return Int(exactly: value)
    }

    static func instanceSizing(
        from snapshot: ConfigurationSnapshot?,
        preservingUserdataBytes: UInt64? = nil
    ) -> InstanceSizing? {
        let bytesPerGiB: UInt64 = 1_073_741_824
        let cpuCount = integerSetting("runtime.cpuCount", in: snapshot) ?? InstanceSizing.default.cpuCount
        let memoryGiB =
            integerSetting("runtime.memoryGiB", in: snapshot)
            ?? Int(InstanceSizing.default.memoryBytes / bytesPerGiB)
        let userdataBytes: UInt64
        if let preservingUserdataBytes {
            userdataBytes = preservingUserdataBytes
        } else {
            let userdataEntry = snapshot?.entries.first(where: { $0.key == "runtime.userdataGiB" })
            if let userdataEntry, userdataEntry.value == .null {
                return nil
            }
            userdataBytes = UInt64(integerSetting("runtime.userdataGiB", in: snapshot) ?? 32) * bytesPerGiB
        }
        return InstanceSizing(
            cpuCount: cpuCount,
            memoryBytes: UInt64(memoryGiB) * bytesPerGiB,
            userdataBytes: userdataBytes
        )
    }

    static func provisioningSizing(
        from snapshot: ConfigurationSnapshot?,
        settingsFile: URL
    ) throws(ImageFailure) -> InstanceSizing {
        guard let sizing = instanceSizing(from: snapshot) else {
            throw userdataCapacityFailure(at: settingsFile)
        }
        return sizing
    }

    private static func userdataCapacityFailure(at settingsFile: URL) -> ImageFailure {
        let volumeURL = settingsFile.deletingLastPathComponent()
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: volumeURL.path)
        let availableBytes = max(0, (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0)
        // Configuration requires the 8 GiB minimum userdata disk plus the 10 GiB free-space reserve.
        let requiredBytes: Int64 = 18 * 1_073_741_824
        return .insufficientSpace(required: requiredBytes, available: availableBytes)
    }

    private static func currentPhysicalFootprintBytes() -> Int64? {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { informationPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    informationPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(information.phys_footprint)
    }

    private static func appSessionUUID(for sessionID: SessionID) -> UUID? {
        guard case .app(let identifier) = sessionID else { return nil }
        return identifier
    }

    private static func wireDisplayState(for state: RuntimeCore.DisplaySlotState) -> WireDisplayState {
        switch state {
        case .free:
            .free
        case .attaching(let sessionID):
            appSessionUUID(for: sessionID).map(WireDisplayState.attaching) ?? .reserved
        case .allocated(let sessionID):
            appSessionUUID(for: sessionID).map(WireDisplayState.allocated) ?? .reserved
        case .releasing(let sessionID):
            appSessionUUID(for: sessionID).map(WireDisplayState.releasing) ?? .reserved
        case .faulted(let fault):
            .faulted(wireDisplayFault(fault))
        }
    }

    private static func wireDisplayFault(_ fault: DisplayFault) -> RuntimeAPI.WireError {
        switch fault {
        case .graphics(let failure):
            RuntimeAPI.WireError(domain: "graphics", code: "graphics.\(failure.code)")
        case .guestAgentUnavailable:
            RuntimeAPI.WireError(domain: "runtime", code: "runtime.guestAgent")
        case .attachTimedOut, .releaseTimedOut, .reconfigurationUncertain:
            RuntimeAPI.WireError(domain: "runtime", code: "runtime.graphics")
        }
    }

    private static func configurationWireError(for error: any Error) -> RuntimeWireError {
        guard let settingsError = error as? GlobalSettingsStoreError else {
            return configurationStartupError
        }
        switch settingsError {
        case .unknownSetting:
            return .runtime(
                "unknownSetting",
                message: "This global setting isn't recognized.",
                remediation: "Run apkrun config list to see supported settings."
            )
        case .invalidSettingValue(_, let allowed):
            return .runtime(
                "invalidSettingValue",
                message: "The requested global setting value isn't supported.",
                remediation: allowed
            )
        case .unsupportedSchema:
            return configurationStartupError
        case .storage:
            let entry = ErrorCatalog.entry(for: "runtime.settingsStorageFailed")
            return RuntimeWireError.runtime(
                "settingsStorageFailed",
                message: entry?.message?["en"] ?? "APKRun couldn't read or save global settings.",
                remediation: entry?.remediation?["en"] ?? "Check permissions for APKRun's data folder, then try again."
            )
        }
    }

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
        case .busy:
            code = "runtime.busy"
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
