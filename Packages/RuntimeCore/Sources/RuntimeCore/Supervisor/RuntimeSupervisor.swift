import DiagnosticsCore
import Foundation
import ImageCore
import VirtualMachineCore

/// The runtime's state (state-machines.md §2). The M1 cut has no suspend.
public enum RuntimeState: Equatable, Sendable {
    /// No VM.
    case stopped
    /// The VM boots; the phase refines progress.
    case booting(BootPhase)
    /// Android reported boot completion (M1: `ready` is `.bootCompleted`).
    case ready
    /// Android is shutting down.
    case stopping
    /// The boot or the VM failed.
    case failed(RuntimeBootFailure)
}

/// Why a client asked for the runtime (runtime-daemon.md §3.1). The M1 cut knows the CLI only.
public enum StartReason: Sendable {
    /// `apkrun dev boot`.
    case cli
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
    case state(RuntimeState)
    /// Bytes from the kernel console (hvc0).
    case console(Data)
    /// Bytes from the logcat port (hvc2) when log capture is on.
    case logcat(Data)
    /// The first-boot settings ran (android-image.md §7.6).
    case firstBootSettingsApplied
    /// A developer console is attached for this boot: `hvc0`, and `hvc1` in developer mode (#014).
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

/// Owns the Android VM: boot, readiness, and stop (runtime-daemon.md §3; first cut for #012-#014).
///
/// `ensureReady` runs steps 0-2, 4, and 5 of runtime-daemon.md §3.2 with the
/// boot timeouts and the stall limit. In M1, `ready` is entered at
/// `.bootCompleted`, because the agents (#072) and the post-boot setup do not
/// exist yet. Developer mode adds the ADB bridge (#015): the loopback forwarder, and the ADB
/// boot signals. The GraphicsCore device of the GPU profile is appended to each boot's definition (#021).
public actor RuntimeSupervisor {
    /// The current state.
    public private(set) var state: RuntimeState = .stopped
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
    private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation
    private let logger: APKLogger
    private let bootLogger: APKLogger
    private let environment: [String: String]
    private var controller: VMController?
    private var tasks: [Task<Void, Never>] = []
    /// The loopback forwarder of developer ADB (`127.0.0.1:6520` to guest vsock 5555), while Android runs.
    private var forwarder: VsockLoopbackForwarder?
    /// The developer's adb client, when adb was found.
    private var adbClient: AdbClient?
    /// Polls ADB for the boot signals until boot completion.
    private var adbPollTask: Task<Void, Never>?
    /// The bundled development Guest Agent, when developer mode is given one (guest-components.md §3).
    private let guestAgentBundle: GuestAgentBundle?
    /// The development Guest Agent of the boot in flight, from the start of the ADB bridge until the boot ends.
    public private(set) var developmentGuestAgent: DevelopmentGuestAgent?
    /// Whether the ADB poller has connected to the development endpoint in this boot.
    private var isADBConnected = false

    /// The loopback TCP port of developer ADB (configuration.md §2.5).
    static let developmentADBPort: UInt16 = 6520
    /// The guest vsock port where adbd listens (android-image.md §7.3).
    static let developmentADBGuestPort: UInt32 = 5555

    /// The progress stream of the boot in flight, finished by `stop()` so that the boot wait ends.
    private var bootProgress: AsyncStream<Progress>.Continuation?
    /// Set by `stop()` during a boot and cleared when the next boot starts. A stop ends the boot
    /// without a failure state, and `stop()` owns the shutdown.
    private var stopRequested = false
    /// True from the start of `ensureReady` until the boot returns or fails.
    private var isBooting = false
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
        guestAgentBundle: GuestAgentBundle? = nil
    ) {
        self.guestAgentBundle = guestAgentBundle
        self.image = image
        self.instanceStore = instanceStore
        self.options = options
        self.diagnostics = diagnostics
        planner = AndroidBootPlanner(platform: platform, paths: diagnostics.paths)
        self.timeouts = timeouts
        self.environment = environment
        let stream = AsyncStream.makeStream(of: RuntimeEvent.self, bufferingPolicy: .bufferingNewest(4096))
        events = stream.stream
        eventContinuation = stream.continuation
        logger = APKLogger(category: RuntimeLogCategory.supervisor, sink: diagnostics.logSink)
        bootLogger = APKLogger(category: ImageLogCategory.boot, sink: diagnostics.logSink)
    }

    /// Boots Android and waits until it reports boot completion.
    public func ensureReady(_ reason: StartReason) async throws(RuntimeBootFailure) {
        // A boot in progress holds the state at `.stopped` until the VM has been created. A second call must not
        // start another boot, and it must not clear `stopRequested` (a stop during the instance load would be lost).
        guard !isBooting else {
            throw .androidBootFailed(detail: "a boot is already in progress")
        }
        guard state == .stopped else {
            if state == .ready {
                return
            }
            throw .androidBootFailed(detail: "the runtime is not stopped")
        }
        stopRequested = false
        isBooting = true
        defer { isBooting = false }
        do {
            try await boot()
        } catch {
            let outcome = stopRequested ? "stopped" : "failed:\(error.qualifiedCode)"
            await fail(error)
            writeBootRecord(outcome: outcome)
            throw error
        }
        writeBootRecord(outcome: "ready")
    }

    /// Stops Android: `reboot -p` over ADB (or over the serial shell when ADB is not connected) in
    /// developer mode, then a forced stop after 20 s (vm.md §9.3).
    public func stop() async {
        guard let controller else {
            // A boot that has not created the VM yet checks this flag before it starts the VM.
            if isBooting {
                stopRequested = true
            }
            return
        }
        stopRequested = true
        await stopGuestAgent()
        bootProgress?.finish()
        transition(to: .stopping)
        if options.developerMode {
            await requestPowerOff(controller)
        }
        if await controller.state != .stopped {
            // Rejected while the VM is starting. The boot then stops the VM itself (see `boot()`).
            try? await controller.stop()
        }
        // Detach before the drain wait. The drain ends only when the VM has stopped, and a boot still starting the
        // VM sees the detached controller and stops it. Waiting while still attached would never return.
        self.controller = nil
        await controller.waitForConsoleLogDrain()
        finishTasks()
        closeDevelopmentChannels()
        shell = nil
        transition(to: .stopped)
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

    private func boot() async throws(RuntimeBootFailure) {
        // The whole-boot limit counts from the start of the boot (runtime-daemon.md §3.2), VM start included.
        let bootStarted = ContinuousClock.now
        // The GPU device is decided before anything is written, so a profile this build cannot run fails here (#021).
        let gpuDevices = try AndroidGraphicsDevices.devices(
            for: options.gpuProfile,
            requiredHostCapabilities: image.manifest.gpuProfiles[options.gpuProfile.rawValue]?.requiredHostCapabilities
        )
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
            plan = try planner.prepareBoot(image: image, instance: instance, options: options)
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
        try await waitForBootCompletion(progress.stream, firstBoot: isFirstBoot, started: bootStarted)
        // The boot is complete: finish the progress stream so that the periodic ticks stop accumulating.
        bootProgress?.finish()
        adbPollTask?.cancel()
        bootProgress = nil

        if let shell {
            try await confirmBootCompleted(shell)
            if isFirstBoot {
                await applyFirstBootSettings(shell)
            }
        }
        if options.developerMode, guestAgentBundle != nil {
            guard let agent = developmentGuestAgent else {
                throw .guestAgent(.startFailed)
            }
            do throws(GuestAgentFailure) {
                try await agent.start(connectTimeout: .seconds(5))
            } catch {
                throw .guestAgent(error)
            }
        }
        try throwIfStopped()
        Perf.mark(.runtimeReady, timeline: diagnostics.perfTimeline)
        transition(to: .ready)
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

    /// Opens the developer ADB bridge: the loopback forwarder, then the ADB poller.
    ///
    /// Neither failure stops the boot. Without the forwarder the ADB signals and `apkrun dev adb`
    /// are unavailable, and the console signals still decide the phases. The forwarder is not
    /// started against a port that another process already uses, because adb would then talk to
    /// that process.
    private func startADBBridge(
        controller: VMController,
        tracker: BootPhaseTracker,
        progress: AsyncStream<Progress>.Continuation
    ) {
        let forwarder = VsockLoopbackForwarder(
            requestedPort: Self.developmentADBPort,
            guestPort: Self.developmentADBGuestPort,
            logSink: diagnostics.logSink,
            connectGuest: { port in
                try await controller.connect(vsockPort: port, timeout: .seconds(5))
            }
        )
        do {
            try forwarder.start()
        } catch {
            logger.warning(
                "Booting without ADB: the loopback forwarder did not start",
                errorCode: error.qualifiedCode
            )
            return
        }
        self.forwarder = forwarder
        do {
            let executable = try AdbClient.resolveExecutable(environment: environment)
            let client = AdbClient(
                executable: executable,
                endpoint: AdbClient.developmentEndpoint,
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
    /// when the ADB request fails or ADB is not connected. The 20 s deadline starts before the request, so the
    /// forced stop follows 20 s after the request, whatever the channel does.
    private func requestPowerOff(_ controller: VMController) async {
        let deadline = ContinuousClock.now + .seconds(20)
        var requested = false
        if isADBConnected, let adbClient {
            logger.notice("Stopping Android with reboot -p over ADB")
            requested = (try? await adbClient.rebootPowerOff()) != nil
        }
        if !requested, let shell {
            logger.notice("Stopping Android with reboot -p over the serial shell")
            requested = (try? await shell.run("su 0 reboot -p", timeout: .seconds(2))) != nil
        }
        guard requested else {
            return
        }
        while ContinuousClock.now < deadline, await controller.state != .stopped {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Stops the Guest Agent of the boot. It runs before the guest powers off, so that the supervisor does not
    /// try to restart an agent that is going down.
    private func stopGuestAgent() async {
        guard let agent = developmentGuestAgent else {
            return
        }
        developmentGuestAgent = nil
        await agent.stop()
    }

    /// Closes the forwarder and forgets the ADB client of the boot that just ended.
    private func closeDevelopmentChannels() {
        forwarder?.stop()
        forwarder = nil
        adbClient = nil
        adbPollTask = nil
        isADBConnected = false
    }

    private func waitForBootCompletion(
        _ progress: AsyncStream<Progress>,
        firstBoot: Bool,
        started: ContinuousClock.Instant
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
                    "Android boot entered \(entered.description, .public) after \(String(describing: ContinuousClock.now - started), .public)"
                )
            }
            switch watch.receive(input, at: .now) {
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

    /// Reads `sys.boot_completed` over the serial shell (the M1 debug channel, #014).
    private func confirmBootCompleted(_ shell: AndroidSerialShell) async throws(RuntimeBootFailure) {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            try throwIfStopped()
            if let reply = try? await shell.run("getprop sys.boot_completed", timeout: .seconds(5)),
                reply.output.split(whereSeparator: \.isNewline).last == "1"
            {
                logger.notice("Android reports sys.boot_completed=1")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw .androidBootFailed(detail: "sys.boot_completed did not become 1 over the serial shell")
    }

    private func applyFirstBootSettings(_ shell: AndroidSerialShell) async {
        for command in FirstBootSettings.commands {
            do {
                let reply = try await shell.run(command, timeout: .seconds(30))
                logger.info("First-boot setting '\(command, .public)' exited \(reply.status, .public)")
            } catch {
                logger.warning(
                    "First-boot setting '\(command, .public)' did not finish: \(String(describing: error), .public)")
                return
            }
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
        .vmStart, .kernelStart, .androidInit, .systemServerReady, .bootCompleted, .runtimeReady,
    ]

    private func fail(_ failure: RuntimeBootFailure) async {
        await stopGuestAgent()
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
        closeDevelopmentChannels()
        controller = nil
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
        eventContinuation.yield(.state(newState))
    }
}
