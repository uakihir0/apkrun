import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeAPI
import RuntimeCore

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
    /// The Guest Agent bundle is missing or invalid.
    case guestAgentBundle(String)
    /// Runtime boot failed.
    case runtimeBoot(RuntimeBootFailure)
    /// The daemon lifecycle record could not be updated.
    case stateStore(DaemonStateStoreError)
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
    private var diagnostics: DiagnosticsContext?
    private var logger: APKLogger?
    private var instanceLock: InstanceLock?
    private var stateStore: DaemonStateStore?
    private var startupAssessment: DaemonStartupAssessment?
    private var image: InstalledImage?
    private var instanceStore: InstanceStore?
    private var supervisor: RuntimeSupervisor?
    private var bootProgressEstimator: BootProgressEstimator?
    private var bootStartedAt: ContinuousClock.Instant?
    private var recordedBootOperationIDs = Set<UUID>()
    private var hostState = "starting"
    private var startupFailure: (step: Int, code: String)?
    private var hasStarted = false
    private var isShuttingDown = false
    private var shutdownCompleted = false
    private var activeLifecycleOperations = 0
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a daemon host for the current user.
    public init(
        paths: APKRunPaths = APKRunPaths(),
        buildInfo: BuildInfo = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? "apkrund")
    ) {
        self.paths = paths
        self.buildInfo = buildInfo
        self.environment = environment
        self.executableURL = executableURL
    }

    /// Performs daemon startup. Missing image or Guest Agent data leaves the daemon degraded so
    /// it can still report a useful status to clients.
    public func start() async throws(RuntimeHostError) {
        guard !hasStarted else {
            throw .alreadyStarted
        }
        guard !isShuttingDown else {
            throw .shuttingDown
        }
        hasStarted = true
        activeLifecycleOperations += 1
        defer { finishLifecycleOperation() }

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
                hasStarted = false
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
                    logger.fault("The previous daemon process did not record a clean exit")
                }
                if assessment.crashLoopActive {
                    logger.error("Three unclean daemon exits occurred within ten minutes")
                }
            } catch {
                recordDegradedStartup(step: 3, code: "hostStartupFailed")
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

        guard !isShuttingDown else { return }
        hostState = startupFailure == nil ? "running" : "degraded"
        logger.notice("Daemon startup completed with host state \(hostState, .public)")
    }

    /// Boots Android on demand. An explicit start is allowed after the crash-loop guard activates.
    public func startRuntime(reason: StartReason = .user) async throws(RuntimeHostError) {
        try beginLifecycleOperation()
        defer { finishLifecycleOperation() }

        if let startupFailure, startupFailure.step == 2 || startupFailure.step == 3 {
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
        try beginLifecycleOperation()
        defer { finishLifecycleOperation() }
        await supervisor?.stop()
    }

    /// Returns a point-in-time view for the control endpoint.
    public func status() async -> RuntimeHostStatus {
        let runtimeStateValue = await supervisor?.state
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
        let crashLoopActive = (try? stateStore?.bootLoopGuardIsActive()) ?? startupAssessment?.crashLoopActive ?? false
        return RuntimeHostStatus(
            hostState: hostState,
            runtimeState: runtimeState,
            bootProgress: bootProgress,
            startupFailureStep: startupFailure?.step,
            startupFailureCode: startupFailure?.code,
            crashLoopActive: crashLoopActive,
            daemonPID: Int32(getpid()),
            imageVersion: image?.version.description
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

    /// Records the daemon-ready marker once its authenticated XPC endpoint is serving.
    public func markDaemonReady() {
        guard let diagnostics else { return }
        Perf.mark(.daemonReady, timeline: diagnostics.perfTimeline)
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
        hostState = "shuttingDown"
        guard hasStarted else {
            hostState = "stopped"
            completeShutdown()
            return
        }
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

    private func waitForLifecycleOperations() async {
        guard activeLifecycleOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            lifecycleWaiters.append(continuation)
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
