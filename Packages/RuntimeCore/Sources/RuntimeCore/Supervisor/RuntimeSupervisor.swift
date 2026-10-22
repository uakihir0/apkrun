import DiagnosticsCore
import Foundation
import GraphicsCore
import GuestProtocol
import ImageCore
import VirtualMachineCore

/// The runtime's state (state-machines.md §2).
public enum RuntimeState: Equatable, Sendable {
    /// No VM.
    case stopped
    /// The VM boots; the phase refines progress.
    case booting(BootPhase)
    /// Android reported boot completion (M1: `ready` is `.bootCompleted`).
    case ready
    /// The VM is paused and will resume before serving guest operations.
    case suspended
    /// Android is shutting down.
    case stopping(StopReason)
    /// The boot or the VM failed.
    case failed(RuntimeBootFailure)
}

/// A runtime state paired with its monotonic position in the supervisor's event stream.
public struct RuntimeStateSnapshot: Equatable, Sendable {
    /// Increments whenever the supervisor changes runtime state.
    public let revision: UInt64
    /// The state at `revision`.
    public let state: RuntimeState

    /// Creates a state snapshot.
    public init(revision: UInt64, state: RuntimeState) {
        self.revision = revision
        self.state = state
    }
}

/// Why the daemon is stopping Android (runtime-daemon.md §3.5).
public enum StopReason: String, Equatable, Sendable {
    /// A user explicitly stopped or restarted Android.
    case user
    /// Android stopped after the idle policy expired.
    case idle
    /// The host is shutting down.
    case hostShutdown
    /// The host is updating APKRun.
    case hostUpdate
    /// Android is stopping for an image migration.
    case migration
    /// Android is stopping for a data reset.
    case reset
    /// Android is stopping after a runtime failure.
    case failure
}

/// Why a client asked for the runtime (runtime-daemon.md §3.1).
public enum StartReason: Sendable {
    /// `apkrun dev boot`.
    case cli
    /// APKRun.app, a wrapper, or another product client.
    case user
    /// A registered package session or other automatic launch request.
    case automatic
    /// The configured one-time start after the user logs in.
    case preboot
}

/// The boot deadlines of runtime-daemon.md §3.2.
public struct BootTimeouts: Equatable, Sendable {
    /// The whole boot (`runtime.bootTimeoutSeconds`).
    public var whole: Duration
    /// The whole first boot of an instance (`runtime.firstBootTimeoutSeconds`).
    public var firstBoot: Duration
    /// No phase progress.
    public var stall: Duration
    /// No phase progress on a first boot.
    public var firstBootStall: Duration

    /// 180 s and 900 s for the whole boot, 90 s and 600 s without progress.
    public static let standard = BootTimeouts(
        whole: .seconds(180),
        firstBoot: .seconds(900),
        stall: .seconds(90),
        firstBootStall: .seconds(600)
    )

    /// Creates a set of deadlines.
    public init(whole: Duration, firstBoot: Duration, stall: Duration, firstBootStall: Duration) {
        self.whole = whole
        self.firstBoot = firstBoot
        self.stall = stall
        self.firstBootStall = firstBootStall
    }
}

/// What the supervisor reports while it runs.
public enum RuntimeEvent: Sendable {
    /// The runtime state changed.
    case state(RuntimeStateSnapshot)
    /// Bytes from the kernel console (hvc0).
    case console(Data)
    /// Bytes from the logcat port (hvc2) when log capture is on.
    case logcat(Data)
    /// The first-boot settings ran (android-image.md §7.6).
    case firstBootSettingsApplied
    /// A developer console is attached for this boot: `hvc0`, and `hvc1` in developer mode (#15).
    case devConsole(DevConsoleEndpoint)
}

/// What the supervisor keeps about one boot until its record is written.
private struct BootDraft: Sendable {
    var started: ContinuousClock.Instant
    var operationID: UUID
    var bootKind: String
    var image: String
    var gpuProfile: String
    var memoryGiB: Int
    var cpuCount: Int
}

/// Owns the Android VM: boot, readiness, and stop (runtime-daemon.md §3; first cut for #13-#15).
///
/// `ensureReady` runs steps 0-2, 4, and 5 of runtime-daemon.md §3.2 with the
/// boot timeouts and the stall limit. In M1, `ready` is entered at
/// `.bootCompleted`, because the agents (#73) and the post-boot setup do not
/// exist yet. Developer mode adds the ADB bridge (#16): the loopback forwarder, and the ADB
/// boot signals. The GraphicsCore device of the GPU profile is appended to each boot's definition (#22).
public actor RuntimeSupervisor {
    /// The current state.
    public private(set) var state: RuntimeState = .stopped
    private var stateRevision: UInt64 = 0
    /// The Guest Agent state retained after the last failed boot.
    private var lastGuestAgentStatus: GuestAgentSupervisor.StatusSnapshot?
    /// State changes and console output, in order. Finishes when the supervisor is released.
    public nonisolated let events: AsyncStream<RuntimeEvent>
    /// The Android serial shell, in developer mode once a boot has started.
    public private(set) var shell: AndroidSerialShell?

    private let image: InstalledImage
    private let instanceStore: InstanceStore
    private let options: BootOptions
    private let diagnostics: DiagnosticsContext
    private let planner: AndroidBootPlanner
    private let timeouts: BootTimeouts
    private let guestAgentTimeout: Duration
    private let requiredAgentOutageTimeout: Duration
    private let bootClock: any RuntimeIdleClock
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let logger: APKLogger
    private let bootLogger: APKLogger
    private let environment: [String: String]
    private let adbClientConnectionCountChanged: @Sendable (UInt64, UInt64, Int) -> Void
    private var controller: VMController?
    /// The boot's GPU device while the VM can still accept host display operations.
    private var graphicsDevice: VirtioGPUDevice?
    /// The lazily created pool-display coordinator for this running boot.
    private var displayPool: DisplayPool?
    private var tasks: [Task<Void, Never>] = []
    /// Watches the required Guest Agent after runtime readiness.
    private var requiredAgentOutageMonitor: RequiredAgentOutageMonitor?
    /// The loopback forwarder of developer ADB (`127.0.0.1:<port>` to guest vsock 5555), while Android runs.
    private var forwarder: VsockLoopbackForwarder?
    /// A separate loopback forwarder for the supervisor's ADB client and Guest Agent.
    private var adbClientForwarder: VsockLoopbackForwarder?
    /// The developer's adb client, when adb was found.
    private var adbClient: AdbClient?
    /// Polls ADB for the boot signals until boot completion.
    private var adbPollTask: Task<Void, Never>?
    /// The bundled development Guest Agent, when developer mode is given one (guest-components.md §3).
    private let guestAgentBundle: GuestAgentBundle?
    /// The development display of scanout 0, or `nil` (`apkrun dev boot --window`, #24).
    private let developmentDisplay: DevelopmentDisplay?
    /// The development Guest Agent of the boot in flight, from the start of the ADB bridge until the boot ends.
    public private(set) var developmentGuestAgent: DevelopmentGuestAgent?
    /// The loopback TCP port that developer ADB is bound to in this boot: `BootOptions.adbHostPort`, or the port the
    /// kernel chose for `0`. Nil while no forwarder runs (developer mode off, or before the ADB bridge starts).
    public var developmentADBHostPort: UInt16? {
        forwarder?.port
    }
    /// The private loopback port used by the supervisor's ADB client and Guest Agent.
    public var developmentADBClientHostPort: UInt16? {
        adbClientForwarder?.port
    }
    /// The latest developer ADB forwarder generation, used by RuntimeHost to reject callbacks after stop.
    public var developmentADBForwarderGeneration: UInt64 {
        adbForwarderGeneration
    }
    /// Whether the ADB poller has connected to the development endpoint in this boot.
    private var isADBConnected = false
    /// Distinguishes callbacks from each replacement loopback forwarder.
    private var adbForwarderGeneration: UInt64 = 0

    /// The guest vsock port where adbd listens (android-image.md §7.3).
    static let developmentADBGuestPort: UInt32 = 5555

    /// The progress stream of the boot in flight, finished by `stop()` so that the boot wait ends.
    private var bootProgress: AsyncStream<Progress>.Continuation?
    /// Set by `stop()` during a boot and cleared when the next boot starts. A stop ends the boot
    /// without a failure state, and `stop()` owns the shutdown.
    private var stopRequested = false
    /// True from the start of `ensureReady` until the boot returns or fails.
    private var isBooting = false
    /// A host sleep overlapped a boot and may require a time sync when Android becomes ready.
    private var hostSleepDuringBoot = false
    private var hostWakeRequiresTimeSync = false
    /// Serializes start, suspend, resume, and stop operations while the actor is reentrant across awaits.
    private var isLifecycleOperationInProgress = false
    private var lifecycleOperationWaiters: [CheckedContinuation<Void, Never>] = []
    /// What `perf/boots.jsonl` needs about the boot in flight. Set once the VM is about to start.
    private var bootDraft: BootDraft?

    /// Creates a supervisor for one image and instance.
    public init(
        image: InstalledImage,
        instanceStore: InstanceStore,
        options: BootOptions,
        diagnostics: DiagnosticsContext,
        platform: VZPlatformProfile = .macOS27,
        timeouts: BootTimeouts = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        guestAgentBundle: GuestAgentBundle? = nil,
        guestAgentTimeout: Duration = DevelopmentGuestAgent.defaultConnectTimeout,
        requiredAgentOutageTimeout: Duration = .seconds(30),
        developmentDisplay: DevelopmentDisplay? = nil,
        adbClientConnectionCountChanged: @escaping @Sendable (UInt64, UInt64, Int) -> Void = { _, _, _ in },
        bootClock: any RuntimeIdleClock = SuspendingRuntimeIdleClock()
    ) {
        self.guestAgentBundle = guestAgentBundle
        self.developmentDisplay = developmentDisplay
        self.image = image
        self.instanceStore = instanceStore
        self.options = options
        self.diagnostics = diagnostics
        planner = AndroidBootPlanner(platform: platform, paths: diagnostics.paths)
        self.timeouts = timeouts
        self.guestAgentTimeout = guestAgentTimeout
        self.requiredAgentOutageTimeout = requiredAgentOutageTimeout
        self.bootClock = bootClock
        self.environment = environment
        self.adbClientConnectionCountChanged = adbClientConnectionCountChanged
        let stream = AsyncStream.makeStream(of: RuntimeEvent.self, bufferingPolicy: .bufferingNewest(4096))
        events = stream.stream
        eventContinuation = stream.continuation
        logger = APKLogger(category: RuntimeLogCategory.supervisor, sink: diagnostics.logSink)
        bootLogger = APKLogger(category: ImageLogCategory.boot, sink: diagnostics.logSink)
    }

    /// Boots Android and waits until it reports boot completion.
    public func ensureReady(_ reason: StartReason) async throws(RuntimeBootFailure) {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        // A boot in progress holds the state at `.stopped` until the VM has been created. A second call must not
        // start another boot, and it must not clear `stopRequested` (a stop during the instance load would be lost).
        guard !isBooting else {
            throw .androidBootFailed(detail: "a boot is already in progress")
        }
        if state == .suspended {
            try await resumeWhileSerialized()
            return
        }
        guard state == .stopped else {
            if state == .ready {
                return
            }
            throw .androidBootFailed(detail: "the runtime is not stopped")
        }
        stopRequested = false
        lastGuestAgentStatus = nil
        isBooting = true
        hostSleepDuringBoot = false
        hostWakeRequiresTimeSync = false
        defer { isBooting = false }
        do {
            try await boot()
            if hostWakeRequiresTimeSync {
                try await synchronizeActiveGuestTime()
                hostWakeRequiresTimeSync = false
                hostSleepDuringBoot = false
            }
        } catch {
            let outcome = stopRequested ? "stopped" : "failed:\(error.qualifiedCode)"
            await fail(error)
            writeBootRecord(outcome: outcome)
            if !stopRequested {
                // Preserve the failure event and boot record for diagnostics, then make a later
                // explicit start retry possible without requiring a daemon restart.
                transition(to: .stopped)
            }
            hostSleepDuringBoot = false
            hostWakeRequiresTimeSync = false
            throw error
        }
        writeBootRecord(outcome: "ready")
    }

    /// Returns a consistent view of the active Guest Agent, or the final state retained after a failed boot.
    public func guestAgentStatusSnapshot() async -> GuestAgentSupervisor.StatusSnapshot? {
        if let developmentGuestAgent {
            return await developmentGuestAgent.supervisor.statusSnapshot()
        }
        return lastGuestAgentStatus
    }

    /// Returns the current state with the revision used by state events.
    public func stateSnapshot() -> RuntimeStateSnapshot {
        RuntimeStateSnapshot(revision: stateRevision, state: state)
    }

    /// Pauses Android after the Guest Agent stops keepalives and request timers.
    public func suspend() async throws(RuntimeBootFailure) {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        try await suspendWhileSerialized()
    }

    /// Pauses a ready runtime before host sleep, or records that an in-progress boot will sleep with its VM.
    ///
    /// Virtualization.framework pauses a booting VM with the host. Boot deadlines use a suspending clock, and boot
    /// performs the initial guest-time sync before entering `ready`.
    public func prepareForHostSleep() async throws(RuntimeBootFailure) -> Bool {
        if isBooting {
            hostSleepDuringBoot = true
            return true
        }
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        guard state == .ready else { return false }
        try await suspendWhileSerialized()
        return true
    }

    /// Completes a host sleep or cancellation for a VM that `prepareForHostSleep()` accepted.
    public func completeHostSleep(cancelled: Bool) async throws(RuntimeBootFailure) {
        if isBooting, state != .ready {
            if cancelled {
                hostSleepDuringBoot = false
                hostWakeRequiresTimeSync = false
            } else {
                hostWakeRequiresTimeSync = true
            }
            return
        }
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        if state == .suspended {
            try await resumeWhileSerialized()
            hostSleepDuringBoot = false
            hostWakeRequiresTimeSync = false
            return
        }
        guard !cancelled, hostSleepDuringBoot, state == .ready else {
            hostSleepDuringBoot = false
            hostWakeRequiresTimeSync = false
            return
        }
        try await synchronizeActiveGuestTime()
        hostSleepDuringBoot = false
        hostWakeRequiresTimeSync = false
    }

    private func synchronizeActiveGuestTime() async throws(RuntimeBootFailure) {
        guard let agent = developmentGuestAgent else { return }
        let roundTrip: Duration
        do throws(GuestAgentFailure) {
            roundTrip = try await agent.resume(connectTimeout: .seconds(2))
        } catch {
            let failure: RuntimeBootFailure =
                error == .connectTimedOut || error == .requiredAgentUnavailable || error == .startFailed
                ? .requiredAgentUnavailable(agent: .guestAgent)
                : .guestAgent(error)
            throw failure
        }
        try await synchronizeGuestTime(roundTrip: roundTrip, using: agent)
    }

    private func suspendWhileSerialized() async throws(RuntimeBootFailure) {
        guard state != .suspended else {
            return
        }
        guard state == .ready, let controller else {
            throw .androidBootFailed(detail: "the runtime is not ready to suspend")
        }
        await stopRequiredAgentOutageMonitor()
        await developmentGuestAgent?.supervisor.pause()
        do {
            try await controller.pause()
        } catch {
            let failure = Self.vmFailure(error)
            await failAndReturnToStopped(failure)
            throw failure
        }
        Perf.mark(.vmPaused, timeline: diagnostics.perfTimeline)
        transition(to: .suspended)
    }

    /// Resumes Android, verifies its required agent, then returns the runtime to `ready`.
    public func resume() async throws(RuntimeBootFailure) {
        await acquireLifecycleOperation()
        defer { releaseLifecycleOperation() }
        try await resumeWhileSerialized()
    }

    private func resumeWhileSerialized() async throws(RuntimeBootFailure) {
        guard state != .ready else {
            return
        }
        guard state == .suspended, let controller else {
            throw .androidBootFailed(detail: "the runtime is not suspended")
        }
        do {
            try await controller.resume()
        } catch {
            let failure = Self.vmFailure(error)
            await failAndReturnToStopped(failure)
            throw failure
        }
        Perf.mark(.vmResumed, timeline: diagnostics.perfTimeline)

        if let agent = developmentGuestAgent {
            let roundTrip: Duration
            do throws(GuestAgentFailure) {
                roundTrip = try await agent.resume(connectTimeout: .seconds(2))
            } catch {
                let failure: RuntimeBootFailure =
                    error == .connectTimedOut || error == .requiredAgentUnavailable || error == .startFailed
                    ? .requiredAgentUnavailable(agent: .guestAgent)
                    : .guestAgent(error)
                await failAndReturnToStopped(failure)
                throw failure
            }
            do {
                try await synchronizeGuestTime(roundTrip: roundTrip, using: agent)
            } catch {
                await failAndReturnToStopped(error)
                throw error
            }
        }
        transition(to: .ready)
        await startRequiredAgentOutageMonitor()
    }

    /// Stops Android: `reboot -p` over ADB (or over the serial shell when ADB is not connected) in
    /// developer mode, then a forced stop after 20 s (vm.md §9.3).
    public func stop(reason: StopReason = .user) async {
        // `stop()` deliberately bypasses the lifecycle gate during boot so that it can cancel the
        // in-flight boot. All other stop calls serialize behind suspend/resume.
        let acquiredLifecycleOperation = !isBooting
        if acquiredLifecycleOperation {
            await acquireLifecycleOperation()
        }
        defer {
            if acquiredLifecycleOperation {
                releaseLifecycleOperation()
            }
        }
        if state == .suspended {
            do {
                try await resumeWhileSerialized()
            } catch {
                // Resume failure already captures diagnostics and stops the VM. Do not attempt a guest shutdown over
                // a connection that could not be restored.
                return
            }
        }
        guard let controller else {
            // A boot that has not created the VM yet checks this flag before it starts the VM.
            if isBooting {
                stopRequested = true
            }
            return
        }
        stopRequested = true
        transition(to: .stopping(reason))
        await stopRequiredAgentOutageMonitor()
        await stopGuestAgent()
        bootProgress?.finish()
        // A forced stop that is rejected while the VM is still starting is left to the boot, which stops the VM itself.
        let powerOff: (@Sendable () async -> Bool)? =
            options.developerMode ? { @Sendable in await self.requestPowerOff() } : nil
        let stoppedByItself = await AndroidStopSequence().run(
            requestPowerOff: powerOff,
            isStopped: { await controller.state == .stopped },
            forceStop: { try? await controller.stop() }
        )
        if options.developerMode, !stoppedByItself {
            logger.warning("Android did not power off in time, so the VM was stopped by force")
        }
        // Detach before the drain wait. The drain ends only when the VM has stopped, and a boot still starting the
        // VM sees the detached controller and stops it. Waiting while still attached would never return.
        self.controller = nil
        await controller.waitForConsoleLogDrain()
        finishTasks()
        await closeDevelopmentChannels()
        displayPool = nil
        graphicsDevice = nil
        shell = nil
        transition(to: .stopped)
    }

    private func acquireLifecycleOperation() async {
        guard isLifecycleOperationInProgress else {
            isLifecycleOperationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleOperationWaiters.append(continuation)
        }
    }

    private func releaseLifecycleOperation() {
        guard !lifecycleOperationWaiters.isEmpty else {
            isLifecycleOperationInProgress = false
            return
        }
        lifecycleOperationWaiters.removeFirst().resume()
    }

    private func failAndReturnToStopped(_ failure: RuntimeBootFailure) async {
        await fail(failure)
        if !stopRequested, state == .failed(failure) {
            transition(to: .stopped)
        }
    }

    private func synchronizeGuestTime(
        roundTrip: Duration,
        using agent: DevelopmentGuestAgent
    ) async throws(RuntimeBootFailure) {
        let unixTimeMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let rttMilliseconds = UInt32(clamping: roundTrip.wholeMilliseconds)
        do throws(GuestProtocolFailure) {
            _ = try await agent.supervisor.send(
                GuestSyncTime(
                    unixTimeMilliseconds: unixTimeMilliseconds,
                    rttMilliseconds: rttMilliseconds
                )
            )
        } catch {
            guard Self.isSyncTimeUnsupported(error) else {
                throw .guestAgent(.operationFailed(reason: String(describing: error)))
            }
            #if DEBUG
                guard options.developerMode, let adbClient else {
                    throw .guestAgent(.operationFailed(reason: String(describing: error)))
                }
                let buildType: String
                do throws(AdbFailure) {
                    buildType = try await adbClient.getprop("ro.build.type")
                } catch {
                    logger.error("The Android build type could not be checked for time sync", errorCode: error.code)
                    throw .guestAgent(.adb(error))
                }
                guard buildType == "userdebug" else {
                    throw .guestAgent(.operationFailed(reason: String(describing: error)))
                }
                do throws(AdbFailure) {
                    try await adbClient.restartAsRoot(timeout: .seconds(60))
                    let seconds = Int64(Date().timeIntervalSince1970.rounded(.down))
                    let reply = try await adbClient.shell("date -u @\(seconds)", timeout: .seconds(5))
                    guard reply.status == 0 else {
                        throw .commandFailed(command: "date", status: reply.status)
                    }
                } catch {
                    logger.error("The Android wall clock could not be synchronized", errorCode: error.qualifiedCode)
                    throw .guestAgent(.adb(error))
                }
                do throws(GuestAgentFailure) {
                    _ = try await agent.resume(connectTimeout: .seconds(10))
                } catch {
                    logger.error(
                        "The Guest Agent did not reconnect after the developer ADB root transition",
                        errorCode: error.qualifiedCode
                    )
                    throw .requiredAgentUnavailable(agent: .guestAgent)
                }
            #else
                throw .guestAgent(.operationFailed(reason: String(describing: error)))
            #endif
        }
    }

    private static func isSyncTimeUnsupported(_ failure: GuestProtocolFailure) -> Bool {
        switch failure {
        case .capabilityMissing(let capability) where capability == GuestCapability.locale.rawValue:
            true
        case .remote(code: .unsupported, _, operation: "SyncTime"):
            true
        default:
            false
        }
    }

    /// Finishes the event stream after the owning daemon has completed its final stop.
    public func finishEventStream() {
        eventContinuation.finish()
    }

    /// Connects to a guest vsock port of the running VM.
    public func connect(vsockPort: UInt32, timeout: Duration) async throws(RuntimeBootFailure) -> VsockConnection {
        guard let controller else {
            throw .androidBootFailed(detail: "the runtime is not running")
        }
        do {
            return try await controller.connect(vsockPort: vsockPort, timeout: timeout)
        } catch {
            throw Self.vmFailure(error)
        }
    }

    /// Creates or returns the display pool for this running VM.
    ///
    /// The pool is available only when this boot has a GraphicsCore device and a connected Guest Agent. It is created
    /// lazily so boots that use only display 0 do not allocate pool state.
    public func makeDisplayPool() -> DisplayPool? {
        guard state == .ready, let graphicsDevice, let developmentGuestAgent else { return nil }
        if let displayPool { return displayPool }
        let pool = DisplayPool(
            scanouts: VirtioGPUScanoutController(device: graphicsDevice),
            guest: developmentGuestAgent,
            primaryPool: developmentDisplay?.currentPoolHandle
        )
        displayPool = pool
        let restartEvents = developmentGuestAgent.androidRestartEvents
        tasks.append(
            Task {
                for await restart in restartEvents {
                    guard !Task.isCancelled else { return }
                    logger.notice(
                        "Android restarted while the VM remained active; resetting display quarantine from uptime \(restart.previousUptimeMillis, .public) ms to \(restart.currentUptimeMillis, .public) ms"
                    )
                    await pool.guestRestarted()
                }
            }
        )
        return pool
    }

    private func boot() async throws(RuntimeBootFailure) {
        // The whole-boot limit counts from the start of the boot (runtime-daemon.md §3.2), VM start included.
        let bootStarted = ContinuousClock.now
        let bootTimeoutStarted = bootClock.now
        // The GPU device is decided before anything is written. For drmVirgl that starts the renderer, so a renderer
        // failure ends the boot here, before the VM is created (#22, #23, graphics.md §8).
        let gpuDevices = try AndroidGraphicsDevices.devices(
            for: options.gpuProfile,
            requiredHostCapabilities: image.manifest.gpuProfiles[options.gpuProfile.rawValue]?.requiredHostCapabilities
        )
        graphicsDevice = gpuDevices.first
        // The display attaches before the guest starts, so the first scanout flush is presented (graphics.md §6.1).
        if let developmentDisplay, let device = gpuDevices.first {
            do throws(GraphicsFailure) {
                try developmentDisplay.attach(to: device)
            } catch {
                throw .graphics(error)
            }
        }
        let instance: InstanceConfiguration
        do throws(ImageFailure) {
            guard let loaded = try await instanceStore.load(image: image) else {
                throw ImageFailure.instanceMissing
            }
            instance = loaded
        } catch {
            throw .image(error)
        }
        try throwIfStopped()
        let isFirstBoot = !instance.firstBootSettingsApplied
        transition(to: .booting(.kernel))

        let plan: AndroidBootPlan
        do {
            var bootOptions = options
            if let developmentDisplay {
                bootOptions.displayDensity = developmentDisplay.mode.densityDpi
            }
            plan = try planner.prepareBoot(image: image, instance: instance, options: bootOptions)
        } catch {
            throw .image(error)
        }
        bootLogger.info(
            "Prepared boot \(plan.bootRecordID.uuidString, .public) of image \(image.version.description, .public) bootconfig sha256 \(plan.bootconfigSHA256, .public) disks \(plan.definition.disks.compactMap(\.identifier).joined(separator: ","), .public) gpu \(options.gpuProfile.rawValue, .public)"
        )
        // The planner leaves `customDevices` empty, so the GPU device is the boot's only custom device (android-image.md §9.2).
        var definition = plan.definition
        definition.customDevices = gpuDevices
        let validated: ValidatedVMDefinition
        do {
            validated = try VMDefinitionValidator().validate(definition)
        } catch {
            throw .vmConfiguration(error)
        }
        let controller = VMController(definition: validated, diagnostics: diagnostics)
        self.controller = controller
        bootDraft = BootDraft(
            started: ContinuousClock.now,
            operationID: plan.bootRecordID,
            bootKind: isFirstBoot ? "firstBoot" : "cold",
            image: image.version.description,
            gpuProfile: options.gpuProfile.rawValue,
            memoryGiB: Int(instance.sizing.memoryBytes / (1024 * 1024 * 1024)),
            cpuCount: instance.sizing.cpuCount
        )

        let progress = AsyncStream.makeStream(of: Progress.self, bufferingPolicy: .unbounded)
        let tracker = BootPhaseTracker()
        attachConsumers(
            to: plan.definition.consolePorts,
            controller: controller,
            tracker: tracker,
            progress: progress.continuation
        )
        stopRequested = false
        bootProgress = progress.continuation
        try throwIfStopped()

        do {
            try await controller.start()
        } catch {
            throw Self.vmFailure(error)
        }
        guard self.controller === controller else {
            // stop() ran while the VM was starting. It cannot stop a starting VM, so this boot stops it,
            // and it does not start the ADB bridge on a supervisor that has been torn down.
            try? await controller.stop()
            throw .androidBootFailed(detail: "the runtime was stopped while starting")
        }
        if options.developerMode {
            startADBBridge(controller: controller, tracker: tracker, progress: progress.continuation)
        }
        try await waitForBootCompletion(
            progress.stream,
            firstBoot: isFirstBoot,
            started: bootTimeoutStarted,
            measurementStarted: bootStarted,
            clock: bootClock
        )
        let requiredAgentDeadline: ContinuousClock.Instant? =
            options.developerMode && guestAgentBundle != nil
            ? ContinuousClock.now + guestAgentTimeout
            : nil
        // The boot is complete: finish the progress stream so that the periodic ticks stop accumulating.
        bootProgress?.finish()
        adbPollTask?.cancel()
        bootProgress = nil

        if let shell {
            try await confirmBootCompleted(shell, before: requiredAgentDeadline)
            if isFirstBoot {
                await applyFirstBootSettings(shell, before: requiredAgentDeadline)
            }
        }
        if options.developerMode, guestAgentBundle != nil {
            guard let agent = developmentGuestAgent else {
                throw .guestAgent(.startFailed)
            }
            guard let requiredAgentDeadline else {
                throw .guestAgent(.connectTimedOut)
            }
            do throws(GuestAgentFailure) {
                try await agent.start(until: requiredAgentDeadline)
            } catch {
                throw Self.requiredAgentStartFailure(
                    error,
                    deadline: requiredAgentDeadline,
                    now: ContinuousClock.now
                )
            }
            Perf.mark(.agentConnected, timeline: diagnostics.perfTimeline)
            if let developmentDisplay {
                do throws(GuestProtocolFailure) {
                    _ = try await agent.supervisor.send(
                        GuestSetDisplayPolicy(
                            displayID: 0,
                            densityDPI: Int32(developmentDisplay.mode.densityDpi),
                            imePolicy: .local
                        )
                    )
                } catch {
                    throw .guestAgent(.operation(error))
                }
                bootLogger.info(
                    "Applied display 0 policy at \(developmentDisplay.mode.densityDpi, .public) dpi for boot \(plan.bootRecordID.uuidString, .public)"
                )
                developmentDisplay.setDensityUpdater { mode in
                    await agent.applyDisplayPolicy(for: mode)
                }
            }
            let roundTrip: Duration
            do throws(GuestAgentFailure) {
                roundTrip = try await agent.resume(connectTimeout: .seconds(2))
            } catch {
                throw .guestAgent(error)
            }
            try await synchronizeGuestTime(roundTrip: roundTrip, using: agent)
        }
        try throwIfStopped()
        Perf.mark(.runtimeReady, timeline: diagnostics.perfTimeline)
        transition(to: .ready)
        await startRequiredAgentOutageMonitor()
    }

    /// What the console and VM watchers report to the boot wait.
    private enum Progress: Sendable {
        case detector(BootPhaseDetector.Event)
        case vmState(VMState)
        case tick
    }

    private func attachConsumers(
        to ports: [ConsolePortDefinition],
        controller: VMController,
        tracker: BootPhaseTracker,
        progress: AsyncStream<Progress>.Continuation
    ) {
        let events = eventContinuation
        let timeline = diagnostics.perfTimeline
        let console = controller.console(.systemConsole).makeByteStream()
        tasks.append(
            Task {
                for await bytes in console.stream {
                    if bytes.isEmpty {
                        console.acknowledgeDrainBarrier()
                        continue
                    }
                    events.yield(.console(bytes))
                    tracker.consume(console: bytes) { event in
                        if case .entered(_, let marker) = event {
                            Perf.mark(marker, timeline: timeline)
                        }
                        progress.yield(.detector(event))
                    }
                    console.acknowledgeConsumedBytes(bytes.count)
                }
                console.acknowledgeStreamEnd()
            }
        )
        let states = controller.stateUpdates
        tasks.append(
            Task {
                for await state in states {
                    progress.yield(.vmState(state))
                }
            }
        )
        tasks.append(
            Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    progress.yield(.tick)
                }
            }
        )
        for port in ports {
            if port.role == .systemConsole {
                events.yield(.devConsole(DevConsoleEndpoint(name: "hvc0", channel: controller.console(port.role))))
            }
            switch port.role {
            case .service(let name) where name == "sensors_control":
                let channel = controller.console(port.role)
                let stream = channel.makeByteStream()
                let logger = logger
                tasks.append(
                    Task {
                        var responder = SensorsResponder()
                        for await bytes in stream.stream {
                            if bytes.isEmpty {
                                stream.acknowledgeDrainBarrier()
                                continue
                            }
                            let reply = responder.consume(bytes)
                            stream.acknowledgeConsumedBytes(bytes.count)
                            guard !reply.isEmpty else { continue }
                            do {
                                try channel.writeHostInput(reply)
                                logger.info("Answered the sensors HAL with an empty sensor mask")
                            } catch {
                                logger.warning(
                                    "Could not answer the sensors HAL: \(String(describing: error), .public)")
                            }
                        }
                        stream.acknowledgeStreamEnd()
                    }
                )
            case .service(let name) where name == "serial":
                events.yield(.devConsole(DevConsoleEndpoint(name: "hvc1", channel: controller.console(port.role))))
                shell = AndroidSerialShell(channel: controller.console(port.role))
            case .log(let name) where name == "logcat":
                let stream = controller.console(port.role).makeByteStream()
                tasks.append(
                    Task {
                        for await bytes in stream.stream {
                            if bytes.isEmpty {
                                stream.acknowledgeDrainBarrier()
                                continue
                            }
                            events.yield(.logcat(bytes))
                            stream.acknowledgeConsumedBytes(bytes.count)
                        }
                        stream.acknowledgeStreamEnd()
                    }
                )
            default:
                continue
            }
        }
    }

    /// Opens the developer ADB bridge and a separate internal ADB endpoint.
    ///
    /// Neither failure stops the boot. The public forwarder reports external connections as user
    /// activity, while the private forwarder carries supervisor and Guest Agent traffic without
    /// affecting the idle policy. The public forwarder is not started against a port that another
    /// process already uses, because adb would then talk to that process.
    private func startADBBridge(
        controller: VMController,
        tracker: BootPhaseTracker,
        progress: AsyncStream<Progress>.Continuation
    ) {
        adbForwarderGeneration &+= 1
        let forwarderGeneration = adbForwarderGeneration
        let connectionCountChanged = adbClientConnectionCountChanged
        let forwarder = VsockLoopbackForwarder(
            requestedPort: options.adbHostPort,
            guestPort: Self.developmentADBGuestPort,
            logSink: diagnostics.logSink,
            connectionCountChanged: { revision, count in
                connectionCountChanged(forwarderGeneration, revision, count)
            },
            connectGuest: { port in
                try await controller.connect(vsockPort: port, timeout: .seconds(5))
            }
        )
        do {
            try forwarder.start()
            self.forwarder = forwarder
        } catch {
            logger.warning(
                "The public ADB loopback forwarder did not start",
                errorCode: error.qualifiedCode
            )
        }

        let adbClientForwarder = VsockLoopbackForwarder(
            requestedPort: 0,
            guestPort: Self.developmentADBGuestPort,
            logSink: diagnostics.logSink,
            connectGuest: { port in
                try await controller.connect(vsockPort: port, timeout: .seconds(5))
            }
        )
        do {
            try adbClientForwarder.start()
            self.adbClientForwarder = adbClientForwarder
        } catch {
            logger.warning(
                "Booting without internal ADB: the loopback forwarder did not start",
                errorCode: error.qualifiedCode
            )
            return
        }
        guard let hostPort = adbClientForwarder.port else {
            logger.warning("Booting without internal ADB: the loopback forwarder has no bound port")
            return
        }
        do {
            let executable = try AdbClient.resolveExecutable(environment: environment)
            let client = AdbClient(
                executable: executable,
                endpoint: AdbClient.loopbackEndpoint(port: hostPort),
                logSink: diagnostics.logSink
            )
            adbClient = client
            if let bundle = guestAgentBundle {
                developmentGuestAgent = DevelopmentGuestAgent(
                    adb: client,
                    bundle: bundle,
                    logSink: diagnostics.logSink
                )
            }
            let task = Task {
                await self.pollADB(client, tracker: tracker, progress: progress)
            }
            adbPollTask = task
            tasks.append(task)
        } catch {
            logger.warning(
                "Booting without ADB signals: adb was not found",
                errorCode: error.qualifiedCode
            )
        }
    }

    /// Connects ADB once the forwarder is up, then reads the boot properties every 500 ms until
    /// `sys.boot_completed` is 1. A read that fails is skipped, and the poll continues.
    private func pollADB(
        _ client: AdbClient,
        tracker: BootPhaseTracker,
        progress: AsyncStream<Progress>.Continuation
    ) async {
        while !Task.isCancelled {
            do {
                try await client.connect(timeout: .seconds(5))
                break
            } catch {
                continue
            }
        }
        guard !Task.isCancelled else {
            return
        }
        isADBConnected = true
        while !Task.isCancelled {
            if let state = try? await readADBState(client) {
                tracker.observe(adb: state) { event in
                    if case .entered(_, let marker) = event {
                        Perf.mark(marker, timeline: diagnostics.perfTimeline)
                    }
                    progress.yield(.detector(event))
                }
                if state.bootCompleted {
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func readADBState(_ client: AdbClient) async throws(AdbFailure) -> AdbBootState {
        let systemServerStartCount = try await client.getprop(AdbBootSignals.systemServerStartCount)
        let bootCompleted = try await client.getprop(AdbBootSignals.bootCompleted)
        return AdbBootState(
            systemServerStarted: !systemServerStartCount.isEmpty,
            bootCompleted: bootCompleted == "1"
        )
    }

    /// Asks Android to power off with `reboot -p`: over ADB when it is connected, and over the serial shell
    /// when the ADB request fails or ADB is not connected. Returns whether a channel was tried (vm.md §9.3).
    private func requestPowerOff() async -> Bool {
        let logger = logger
        var adb: (@Sendable () async -> Bool)?
        if isADBConnected, let client = adbClient {
            adb = { @Sendable in
                logger.notice("Stopping Android with reboot -p over ADB")
                return (try? await client.rebootPowerOff()) != nil
            }
        }
        var serial: (@Sendable () async -> Bool)?
        if let shell {
            serial = { @Sendable in
                logger.notice("Stopping Android with reboot -p over the serial shell")
                return (try? await shell.run("su 0 reboot -p", timeout: .seconds(2))) != nil
            }
        }
        return await AndroidStopSequence.sendPowerOff(overADB: adb, overShell: serial)
    }

    /// Stops the Guest Agent of the boot. It runs before the guest powers off, so that the supervisor does not
    /// try to restart an agent that is going down.
    private func stopGuestAgent(preservingFailureStatus: Bool = false) async {
        guard let agent = developmentGuestAgent else {
            return
        }
        let status = await agent.supervisor.statusSnapshot()
        developmentGuestAgent = nil
        lastGuestAgentStatus = Self.guestAgentStatusAfterStop(status, preservingFailure: preservingFailureStatus)
        await agent.stop()
    }

    /// Teardown ends live connection states. Keep terminal diagnosis and negotiated protocol information available.
    static func guestAgentStatusAfterStop(
        _ status: GuestAgentSupervisor.StatusSnapshot,
        preservingFailure: Bool
    ) -> GuestAgentSupervisor.StatusSnapshot {
        guard preservingFailure else {
            return GuestAgentSupervisor.StatusSnapshot(state: .stopped, protocolVersion: nil)
        }
        let state: GuestAgentSupervisor.State =
            switch status.state {
            case .connecting, .ready, .reconnecting, .paused, .unresponsive:
                .unavailable
            case .incompatible, .stopped, .unavailable:
                status.state
            }
        return GuestAgentSupervisor.StatusSnapshot(state: state, protocolVersion: status.protocolVersion)
    }

    /// Closes both forwarders and forgets the ADB client of the boot that just ended.
    /// Each forwarder is awaited without blocking a thread of the Swift concurrency pool, so a teardown after a
    /// failed boot cannot hold it.
    private func closeDevelopmentChannels() async {
        let closing = forwarder
        let closingADBClient = adbClientForwarder
        forwarder = nil
        adbClientForwarder = nil
        adbClient = nil
        adbPollTask = nil
        isADBConnected = false
        await closing?.stopAndWait()
        await closingADBClient?.stopAndWait()
    }

    private func waitForBootCompletion(
        _ progress: AsyncStream<Progress>,
        firstBoot: Bool,
        started: Duration,
        measurementStarted: ContinuousClock.Instant,
        clock: any RuntimeIdleClock
    ) async throws(RuntimeBootFailure) {
        var watch = BootWatch(
            started: started,
            whole: firstBoot ? timeouts.firstBoot : timeouts.whole,
            stall: firstBoot ? timeouts.firstBootStall : timeouts.stall
        )
        // VMController yields its initial `.stopped` before the VM starts. That update is not a stop,
        // so a stop counts only after the VM has reported starting.
        var vmStarted = false
        for await item in progress {
            try throwIfStopped()
            let input: BootWatch.Input
            switch item {
            case .detector(.entered(let entered, _)):
                input = .entered(entered)
            case .detector(.failed(let failure)):
                input = .detectorFailed(failure)
            case .vmState(.failed(let failure)):
                input = .vmFailed(failure)
            case .vmState(.starting), .vmState(.running):
                vmStarted = true
                input = .tick
            case .vmState(.stopped):
                if vmStarted, case .booting = state {
                    input = .guestStopped
                } else {
                    input = .tick
                }
            case .vmState, .tick:
                input = .tick
            }
            if case .entered(let entered) = input {
                transition(to: .booting(entered))
                logger.info(
                    "Android boot entered \(entered.description, .public) after \(String(describing: ContinuousClock.now - measurementStarted), .public)"
                )
            }
            switch watch.receive(input, at: clock.now) {
            case .keepWaiting:
                continue
            case .bootCompleted:
                return
            case .fail(let failure):
                throw failure
            }
        }
        try throwIfStopped()
        throw .androidBootFailed(detail: "the console closed while booting")
    }

    /// Ends the boot when `stop()` arrived while it was running. `stop()` owns the shutdown.
    private func throwIfStopped() throws(RuntimeBootFailure) {
        if stopRequested {
            throw .androidBootFailed(detail: "the runtime was stopped during boot")
        }
    }

    /// Reads `sys.boot_completed` over the serial shell (the M1 debug channel, #15).
    private func confirmBootCompleted(
        _ shell: AndroidSerialShell,
        before requiredAgentDeadline: ContinuousClock.Instant?
    ) async throws(RuntimeBootFailure) {
        let normalDeadline = ContinuousClock.now + .seconds(30)
        let deadline = min(normalDeadline, requiredAgentDeadline ?? normalDeadline)
        while ContinuousClock.now < deadline {
            try throwIfStopped()
            let remaining = deadline - ContinuousClock.now
            if let reply = try? await shell.run(
                "getprop sys.boot_completed",
                timeout: min(.seconds(5), remaining)
            ),
                reply.output.split(whereSeparator: \.isNewline).last == "1"
            {
                logger.notice("Android reports sys.boot_completed=1")
                return
            }
            let sleepDuration = min(.milliseconds(500), deadline - ContinuousClock.now)
            if sleepDuration > .zero {
                try? await Task.sleep(for: sleepDuration)
            }
        }
        if let requiredAgentDeadline, ContinuousClock.now >= requiredAgentDeadline {
            throw .requiredAgentUnavailable(agent: .guestAgent)
        }
        throw .androidBootFailed(detail: "sys.boot_completed did not become 1 over the serial shell")
    }

    private func applyFirstBootSettings(
        _ shell: AndroidSerialShell,
        before requiredAgentDeadline: ContinuousClock.Instant?
    ) async {
        for command in FirstBootSettings.commands {
            let remaining = requiredAgentDeadline.map { $0 - ContinuousClock.now } ?? .seconds(30)
            guard remaining > .zero else {
                return
            }
            do {
                let reply = try await shell.run(command, timeout: min(.seconds(30), remaining))
                logger.info("First-boot setting '\(command, .public)' exited \(reply.status, .public)")
            } catch {
                logger.warning(
                    "First-boot setting '\(command, .public)' did not finish: \(String(describing: error), .public)")
                return
            }
        }
        if let requiredAgentDeadline, ContinuousClock.now >= requiredAgentDeadline {
            return
        }
        do {
            try await instanceStore.markFirstBootSettingsApplied()
            eventContinuation.yield(.firstBootSettingsApplied)
        } catch {
            logger.warning("Could not record the first-boot settings: \(error.qualifiedCode, .public)")
        }
    }

    private static func vmFailure(_ error: any Error) -> RuntimeBootFailure {
        if let failure = error as? VMFailure {
            return .vm(failure)
        }
        return .androidBootFailed(detail: "the VM controller failed: \(type(of: error))")
    }

    /// Promotes only a connect timeout that actually exhausted RuntimeSupervisor's required-agent deadline.
    ///
    /// Direct DevelopmentGuestAgent.start() callers keep the lower-level `connectTimedOut` failure.
    static func requiredAgentStartFailure(
        _ failure: GuestAgentFailure,
        deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) -> RuntimeBootFailure {
        if failure == .connectTimedOut, now >= deadline {
            return .requiredAgentUnavailable(agent: .guestAgent)
        }
        return .guestAgent(failure)
    }

    private func startRequiredAgentOutageMonitor() async {
        guard state == .ready, !stopRequested, let agent = developmentGuestAgent else { return }
        let updates = await agent.supervisor.stateUpdates()
        guard state == .ready, !stopRequested, developmentGuestAgent === agent else { return }

        let monitor = RequiredAgentOutageMonitor(timeout: requiredAgentOutageTimeout) { [weak self] in
            await self?.requiredAgentOutageExpired(for: agent)
        }
        requiredAgentOutageMonitor = monitor
        await monitor.watch(updates)
    }

    private func stopRequiredAgentOutageMonitor() async {
        let monitor = requiredAgentOutageMonitor
        requiredAgentOutageMonitor = nil
        await monitor?.stop()
    }

    private func requiredAgentOutageExpired(for agent: DevelopmentGuestAgent) async {
        guard state == .ready, !stopRequested, developmentGuestAgent === agent else { return }
        let status = await agent.supervisor.statusSnapshot()
        guard state == .ready, !stopRequested, developmentGuestAgent === agent, status.state != .ready else { return }
        let failure = RuntimeBootFailure.requiredAgentUnavailable(agent: .guestAgent)
        transition(to: .failed(failure))
        await fail(failure)
        if !stopRequested, state == .failed(failure) {
            // The failure transition is observable before cleanup completes; returning to stopped makes a later
            // explicit ensureReady eligible to start a fresh runtime.
            transition(to: .stopped)
        }
    }

    /// Appends the boot's record to `perf/boots.jsonl`. A boot that never started the VM has none.
    private func writeBootRecord(outcome: String) {
        guard let draft = bootDraft else {
            return
        }
        bootDraft = nil
        let events = diagnostics.perfTimeline.snapshot().filter { $0.time >= draft.started }
        guard let origin = events.first(where: { $0.marker == .vmStart })?.time else {
            return
        }
        var markers: [String: Double] = [:]
        for event in events where Self.recordedMarkers.contains(event.marker) {
            let components = (event.time - origin).components
            markers[event.marker.rawValue] =
                Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
        }
        let record = BootRecord(
            recordedAt: Date(),
            operationID: draft.operationID,
            bootKind: draft.bootKind,
            image: draft.image,
            gpuProfile: draft.gpuProfile,
            memoryGiB: draft.memoryGiB,
            cpuCount: draft.cpuCount,
            markers: markers,
            outcome: outcome
        )
        do {
            try BootRecordLog.append(record, to: diagnostics.paths.bootPerformanceFile)
        } catch {
            logger.warning("Could not write the boot record: \(String(describing: error), .public)")
        }
    }

    /// The markers of `perf/boots.jsonl` (diagnostics.md §4.3).
    private static let recordedMarkers: Set<PerfMarker> = [
        .vmStart, .kernelStart, .androidInit, .systemServerReady, .bootCompleted, .agentConnected, .runtimeReady,
    ]

    private func fail(_ failure: RuntimeBootFailure) async {
        await stopRequiredAgentOutageMonitor()
        await stopGuestAgent(preservingFailureStatus: !stopRequested)
        bootProgress?.finish()
        bootProgress = nil
        if stopRequested {
            // A stop ended this boot. `stop()` owns the state and the graceful power-off, so this path does not move
            // the state to failed. A VM that is still running is stopped here all the same, so that a boot ended by
            // a stop during start does not leave the VM running.
            logger.notice("Android boot ended by a stop request")
        } else {
            logger.error("Android boot failed", errorCode: failure.qualifiedCode)
            transition(to: .failed(failure))
        }
        if let controller {
            if await controller.state != .stopped {
                try? await controller.stop()
            }
            await controller.waitForConsoleLogDrain()
        }
        finishTasks()
        await closeDevelopmentChannels()
        controller = nil
        displayPool = nil
        graphicsDevice = nil
        shell = nil
    }

    private func finishTasks() {
        for task in tasks {
            task.cancel()
        }
        tasks.removeAll()
    }

    private func transition(to newState: RuntimeState) {
        guard state != newState else {
            return
        }
        state = newState
        stateRevision &+= 1
        eventContinuation.yield(
            .state(RuntimeStateSnapshot(revision: stateRevision, state: newState))
        )
    }
}
