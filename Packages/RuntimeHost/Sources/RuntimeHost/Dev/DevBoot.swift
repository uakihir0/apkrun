import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore

/// The GPU profile of `apkrun dev boot --gpu` (cli.md §5; runtime-api.md §15).
///
/// `none` stays the default of `apkrun dev boot` until the drmVirgl boot is verified on the VM (IR-584).
public enum DevGPUProfile: String, CaseIterable, Sendable {
    /// `none`: the development `headless` profile, where VZ's 2D device is the DRM device (#012).
    case none
    /// `swiftshader`: the `guestSwiftshader` profile, which needs no host renderer (#021).
    case swiftshader
    /// `virgl`: the `drmVirgl` profile, which renders through the VirGL renderer on the host (#022).
    case virgl

    /// The bundle's GPU profile that the boot uses.
    var profile: GPUProfileID {
        switch self {
        case .none: .headless
        case .swiftshader: .guestSwiftshader
        case .virgl: .drmVirgl
        }
    }
}

/// Inputs for `apkrun dev boot` (cli.md §5; #012-#014, #021).
public struct DevBootOptions: Sendable {
    /// The GPU profile of the boot. `none` is the default.
    public var gpu: DevGPUProfile
    /// Guest vCPUs of a newly provisioned instance.
    public var cpuCount: Int
    /// Guest memory in bytes of a newly provisioned instance.
    public var memoryBytes: UInt64
    /// Logical `userdata.img` size in bytes of a newly provisioned instance.
    public var userdataBytes: UInt64
    /// Provision a fresh instance even if one exists ("Reset Android").
    public var resetInstance: Bool
    /// Stop the VM once Android is ready, instead of waiting for a stop request.
    public var stopWhenReady: Bool
    /// The directory of the Guest Agent bundle (`apkrun-guest.apk` and `apkrun-guest.json`), which the boot installs
    /// and starts (guest-components.md §3). Nil boots without the agent.
    public var guestAgentDirectory: URL?
    /// A package to launch on display 0 once Android is ready (`apkrun dev launch`, #072). Nil launches nothing.
    public var launchPackage: String?
    /// An optional APK to install before launching `launchPackage` (#026).
    public var launchAPKURL: URL?
    /// The window's connection to display 0 (`apkrun dev boot --window`, #023). Nil shows nothing. It needs `drmVirgl`.
    public var developerDisplay: DeveloperDisplay?
    /// The development input route of the window (#024). Nil binds no input. It is bound once the Guest Agent is ready,
    /// and it is unbound before Android stops.
    public var inputRoute: DevInputRoute?

    /// Creates options for one development boot.
    public init(
        gpu: DevGPUProfile = .none,
        cpuCount: Int = InstanceSizing.default.cpuCount,
        memoryBytes: UInt64 = InstanceSizing.default.memoryBytes,
        userdataBytes: UInt64 = InstanceSizing.default.userdataBytes,
        resetInstance: Bool = false,
        stopWhenReady: Bool = false,
        guestAgentDirectory: URL? = nil,
        launchPackage: String? = nil,
        launchAPKURL: URL? = nil,
        developerDisplay: DeveloperDisplay? = nil,
        inputRoute: DevInputRoute? = nil
    ) {
        self.gpu = gpu
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.userdataBytes = userdataBytes
        self.resetInstance = resetInstance
        self.stopWhenReady = stopWhenReady
        self.guestAgentDirectory = guestAgentDirectory
        self.launchPackage = launchPackage
        self.launchAPKURL = launchAPKURL
        self.developerDisplay = developerDisplay
        self.inputRoute = inputRoute
    }
}

/// What `apkrun dev boot` reports while it runs.
public enum DevBootEvent: Sendable {
    /// A runtime state change, as text (`booting(init)`, `ready`, …).
    case state(String)
    /// Bytes from the kernel console.
    case console(Data)
    /// A one-line status message for the developer.
    case message(String)
    /// A human-readable development warning.
    case warning(String)
    /// A development warning from the error catalog (cliExit 0). It prints with its `hint:` and `code:` lines.
    case catalogWarning(any APKRunError)
}

/// Boots the Android image of a development bundle inside the embedded CLI process.
public struct DevBoot: Sendable {
    /// Creates the development boot runner.
    public init() {}

    /// Boots the current image, provisions the instance if needed, and waits for a stop request.
    ///
    /// The instance lock is held for the whole run. The current image is checked quickly before
    /// the boot (android-image.md §9.3). An instance made from another image version is refused,
    /// because migration arrives with #058; `--reset` provisions a new instance instead. Developer
    /// mode is always on: the Android serial shell answers on hvc1, and logcat is captured to
    /// `<logs>/guest/logcat-<timestamp>.log` (android-image.md §7.1).
    public func run(
        options: DevBootOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stopRequests: AsyncStream<Void>,
        appCloseRequests: AsyncStream<Void>? = nil,
        onEvent: @escaping @Sendable (DevBootEvent) -> Void
    ) async throws {
        // Every log line of the boot carries one operation ID (AGENTS §8).
        try await OperationContext.withNew {
            try await execute(
                options: options,
                environment: environment,
                stopRequests: stopRequests,
                appCloseRequests: appCloseRequests,
                onEvent: onEvent
            )
        }
    }

    private func execute(
        options: DevBootOptions,
        environment: [String: String],
        stopRequests: AsyncStream<Void>,
        appCloseRequests: AsyncStream<Void>?,
        onEvent: @escaping @Sendable (DevBootEvent) -> Void
    ) async throws {
        let paths = APKRunPaths(allowingHomeOverride: true, environment: environment)
        let lock = try InstanceLock.acquire(paths: paths, owner: .apkrunDev)
        defer { lock.close() }
        let diagnostics = DiagnosticsContext.live(paths: paths)

        let images = ImageStore(paths: paths, trust: .standard(), diagnostics: diagnostics)
        try await images.removeOrphanedInstalls()
        let image = try await images.current()
        try await images.verify(image, depth: .quick)
        onEvent(.message("image \(image.version.description) (current)"))
        let store = InstanceStore(paths: paths, diagnostics: diagnostics)
        let sizing = InstanceSizing(
            cpuCount: options.cpuCount,
            memoryBytes: options.memoryBytes,
            userdataBytes: options.userdataBytes
        )
        if options.resetInstance {
            _ = try await store.resetAndroid(image: image, sizing: sizing)
            onEvent(.message("reset the Android instance"))
        } else if let existing = try await store.load(image: image) {
            guard existing.imageVersion == image.version else {
                throw ImageFailure.instanceCorrupt(
                    reason:
                        "the instance uses \(existing.imageVersion.description), not \(image.version.description); use --reset"
                )
            }
        } else {
            _ = try await store.provision(image: image, sizing: sizing)
            onEvent(.message("provisioned a new Android instance"))
        }

        let guestAgentBundle = try options.guestAgentDirectory.map { try GuestAgentBundle.load(directory: $0) }
        let supervisor = RuntimeSupervisor(
            image: image,
            instanceStore: store,
            options: BootOptions(
                gpuProfile: options.gpu.profile,
                developerMode: true,
                captureLogcat: true
            ),
            diagnostics: diagnostics,
            guestAgentBundle: guestAgentBundle,
            developmentDisplay: options.developerDisplay?.core
        )
        var embeddedSession: EmbeddedRuntimeService?
        if let package = options.launchPackage, options.developerDisplay != nil {
            let service = EmbeddedRuntimeService(logSink: diagnostics.logSink)
            _ = try await service.requestSession(packageID: package)
            embeddedSession = service
        }
        // The window's events end with the boot, so it can close after Android has stopped.
        defer {
            options.developerDisplay?.finish()
        }
        let logcat = try LogcatFile(directory: paths.logsRoot.appendingPathComponent("guest", isDirectory: true))
        onEvent(.message("logcat goes to \(logcat.url.path)"))
        let consoles = DevConsoleSocketServer(directory: paths.devConsoleDirectory)
        let eventTask = Task {
            for await event in supervisor.events {
                switch event {
                case .state(let state):
                    onEvent(.state(Self.describe(state)))
                case .console(let bytes):
                    onEvent(.console(bytes))
                case .logcat(let bytes):
                    logcat.write(bytes)
                case .firstBootSettingsApplied:
                    onEvent(.message("applied the first-boot settings (Bluetooth off, Wi-Fi on VirtWifi)"))
                case .devConsole(let endpoint):
                    do throws(RuntimeFailure) {
                        try consoles.serve(endpoint)
                        onEvent(.message("developer console \(endpoint.name) is on \(paths.devConsoleDirectory.path)"))
                    } catch {
                        onEvent(
                            .warning("the developer console \(endpoint.name) is unavailable: \(error.qualifiedCode)"))
                    }
                }
            }
        }
        defer {
            eventTask.cancel()
            consoles.stop()
            logcat.close()
        }

        let stopSignal = DevBootStopSignal()
        await stopSignal.attachStopHandler { await supervisor.stop() }
        let stopRequestMonitor = Self.observeStopRequests(
            stopRequests: stopRequests,
            appCloseRequests: appCloseRequests,
            signal: stopSignal
        )
        var taskEventMonitor: Task<Void, Never>?
        defer {
            stopRequestMonitor.cancel()
            taskEventMonitor?.cancel()
        }
        var stopCause: StopCause = .signal
        let started = ContinuousClock.now
        if await stopSignal.current() == nil {
            do {
                try await supervisor.ensureReady(.cli)
                if await stopSignal.current() == nil {
                    onEvent(.message("Android is ready after \(ContinuousClock.now - started)"))
                }
            } catch {
                guard let requestedStop = await stopSignal.current() else {
                    throw error
                }
                stopCause = requestedStop
            }
        }
        // The window's input reaches display 0 through the Guest Agent (#024). It is bound before the launch.
        var inputBinding: Task<Void, Never>?
        do {
            if let requestedStop = await stopSignal.current() {
                stopCause = requestedStop
            } else if let embeddedSession {
                _ = try await embeddedSession.displayReady()
            }
            if await stopSignal.current() == nil, let route = options.inputRoute {
                if let agent = await supervisor.developmentGuestAgent {
                    let binding = DevInputBinding(route: route, agent: agent, logSink: diagnostics.logSink)
                    inputBinding = Task { await binding.run(report: onEvent) }
                } else {
                    onEvent(.catalogWarning(RuntimeFailure.inputNotBound(cause: nil)))
                }
            }
            if let package = options.launchPackage, await stopSignal.current() == nil {
                guard let agent = await supervisor.developmentGuestAgent else {
                    throw GuestAgentFailure.startFailed
                }
                if let apkURL = options.launchAPKURL {
                    try await agent.installAPK(apkURL, package: package)
                }
                var mayLaunch = true
                if let embeddedSession {
                    _ = try await embeddedSession.beginLaunch()
                    taskEventMonitor = Task {
                        for await event in agent.taskEvents {
                            guard let snapshot = await embeddedSession.taskEvent(event) else {
                                continue
                            }
                            if snapshot.state == .ended(.appExited) {
                                await stopSignal.signal(.appExited)
                                return
                            }
                        }
                    }
                    mayLaunch = await stopSignal.beginLaunch()
                }
                if mayLaunch, await stopSignal.current() == nil {
                    let frameCountBeforeLaunch = options.developerDisplay?.windowFrameCommitCount ?? 0
                    let report = try await agent.launch(package: package, displayID: 0)
                    if let embeddedSession {
                        let snapshot = try await embeddedSession.launched(taskID: report.taskID)
                        if snapshot.state == .ended(.appExited) {
                            await stopSignal.signal(.appExited)
                        }
                    }
                    onEvent(
                        .message(
                            "launched \(package) on display 0: task \(report.taskID) \(report.component) (\(report.outcome))"
                        )
                    )
                    if let display = options.developerDisplay {
                        switch await Self.waitForFrame(
                            after: frameCountBeforeLaunch,
                            on: display,
                            stopSignal: stopSignal
                        ) {
                        case .presented:
                            if let embeddedSession {
                                _ = try await embeddedSession.firstFramePresented()
                            }
                        case .timedOut:
                            if embeddedSession != nil {
                                onEvent(
                                    .warning("Android launched the app, but display 0 has not produced a new frame yet")
                                )
                            }
                        case .stopped(let cause):
                            stopCause = cause
                        }
                    }
                }
            }
            if let requestedStop = await stopSignal.current() {
                stopCause = requestedStop
            } else if !options.stopWhenReady {
                onEvent(.message("press Ctrl-C to stop Android"))
                stopCause = await stopSignal.wait()
            }
        } catch {
            if let requestedStop = await stopSignal.current() {
                stopCause = requestedStop
            } else {
                // A failed launch still stops Android, so the VM and the agent do not run on after the command fails.
                _ = try? await embeddedSession?.fail(.runtimeFailed)
                await endInput(inputBinding, route: options.inputRoute)
                await stopSignal.stopRuntime()
                throw error
            }
            await endInput(inputBinding, route: options.inputRoute)
        }
        // The counters of the route are read before the route is unbound, which discards its router (input.md §11).
        if let route = options.inputRoute {
            onEvent(.message("input counters: \(await route.counters())"))
        }
        if let agent = await supervisor.developmentGuestAgent {
            onEvent(.message("adb shell commands so far: \(await agent.adbShellInvocationCount)"))
        }
        onEvent(.message("stopping Android"))
        await endInput(inputBinding, route: options.inputRoute)
        if stopCause == .appWindowClosed,
            let package = options.launchPackage,
            let embeddedSession,
            let agent = await supervisor.developmentGuestAgent
        {
            _ = try? await embeddedSession.windowClosed()
            do {
                if try await agent.stopApplication(package: package) {
                    _ = await embeddedSession.taskVanished()
                    onEvent(.message("finished Android tasks for \(package)"))
                } else {
                    onEvent(.warning("Android still reports tasks for \(package) after the close request"))
                }
            } catch {
                onEvent(.warning("could not finish Android tasks for \(package): \(error.qualifiedCode)"))
            }
        }
        await stopSignal.stopRuntime()
        _ = try? await embeddedSession?.runtimeStopped()
    }

    enum StopCause: Sendable, Equatable {
        case signal
        case appWindowClosed
        case appExited
    }

    enum FrameWaitResult: Sendable, Equatable {
        case presented
        case timedOut
        case stopped(StopCause)
    }

    static func observeStopRequests(
        stopRequests: AsyncStream<Void>,
        appCloseRequests: AsyncStream<Void>?,
        signal: DevBootStopSignal
    ) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: StopCause.self) { group in
                group.addTask {
                    for await _ in stopRequests {
                        return .signal
                    }
                    return .signal
                }
                if let appCloseRequests {
                    group.addTask {
                        for await _ in appCloseRequests {
                            return .appWindowClosed
                        }
                        return .signal
                    }
                }
                let cause = await group.next() ?? .signal
                await signal.signal(cause)
                group.cancelAll()
            }
        }
    }

    static func waitForFrame(
        after sequence: UInt64,
        on display: DeveloperDisplay,
        stopSignal: DevBootStopSignal,
        timeout: Duration = .seconds(15),
        pollInterval: Duration = .milliseconds(50)
    ) async -> FrameWaitResult {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let cause = await stopSignal.current() {
                return .stopped(cause)
            }
            if display.windowFrameCommitCount > sequence {
                return .presented
            }
            try? await Task.sleep(for: pollInterval)
        }
        if let cause = await stopSignal.current() {
            return .stopped(cause)
        }
        return .timedOut
    }

    /// Stops the input binding, and unbinds the route. The unbinding sends `cancelAll` while the agent still runs, so
    /// the guest releases every gesture and button that is open (input.md §7.3, #024).
    private func endInput(_ binding: Task<Void, Never>?, route: DevInputRoute?) async {
        binding?.cancel()
        await binding?.value
        await route?.unbind()
    }

    static func describe(_ state: RuntimeState) -> String {
        switch state {
        case .stopped: "stopped"
        case .booting(let phase): "booting(\(phase))"
        case .ready: "ready"
        case .stopping: "stopping"
        case .failed(let failure): "failed(\(failure.qualifiedCode))"
        }
    }
}

actor DevBootStopSignal {
    private var cause: DevBoot.StopCause?
    private var waiter: CheckedContinuation<DevBoot.StopCause, Never>?
    private var applicationLaunchStarted = false
    private var stopHandler: (@Sendable () async -> Void)?
    private var stopTask: Task<Void, Never>?

    func attachStopHandler(_ handler: @escaping @Sendable () async -> Void) {
        stopHandler = handler
        if let cause, shouldStopRuntimeImmediately(for: cause) {
            scheduleStop(using: handler)
        }
    }

    func beginLaunch() -> Bool {
        guard cause == nil else {
            return false
        }
        applicationLaunchStarted = true
        return true
    }

    func signal(_ cause: DevBoot.StopCause) {
        guard self.cause == nil else {
            return
        }
        self.cause = cause
        waiter?.resume(returning: cause)
        waiter = nil
        if shouldStopRuntimeImmediately(for: cause), let stopHandler {
            scheduleStop(using: stopHandler)
        }
    }

    func current() -> DevBoot.StopCause? {
        cause
    }

    func wait() async -> DevBoot.StopCause {
        if let cause {
            return cause
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    func stopRuntime() async {
        guard let stopHandler else {
            return
        }
        scheduleStop(using: stopHandler)
        await stopTask?.value
    }

    private func shouldStopRuntimeImmediately(for cause: DevBoot.StopCause) -> Bool {
        switch cause {
        case .appWindowClosed:
            !applicationLaunchStarted
        case .signal, .appExited:
            true
        }
    }

    private func scheduleStop(using handler: @escaping @Sendable () async -> Void) {
        guard stopTask == nil else {
            return
        }
        stopTask = Task { await handler() }
    }
}

/// Where the development Guest Agent bundle is (guest-components.md §7.1, build-system.md §7.1). The order is the
/// `--guest-dir` value, then `APKRUN_GUEST_DIR`, then `Resources/guest` of the app bundle that holds the executable.
public enum DevGuestAgentLocation {
    /// The bundle directory for `guestDir` (the flag value, or nil), `environment`, and `executable`.
    public static func directory(
        guestDir: String?,
        environment: [String: String],
        executable: URL
    ) -> URL {
        if let guestDir, !guestDir.isEmpty {
            return URL(fileURLWithPath: guestDir, isDirectory: true)
        }
        if let fromEnvironment = environment["APKRUN_GUEST_DIR"], !fromEnvironment.isEmpty {
            return URL(fileURLWithPath: fromEnvironment, isDirectory: true)
        }
        return
            executable
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/guest", isDirectory: true)
    }
}

/// The logcat capture of one development boot.
private final class LogcatFile: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let lock = NSLock()

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        url = directory.appendingPathComponent("logcat-\(formatter.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) {
        lock.withLock { try? handle.write(contentsOf: data) }
    }

    func close() {
        lock.withLock { try? handle.close() }
    }
}
