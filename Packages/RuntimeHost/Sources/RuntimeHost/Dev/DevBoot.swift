import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeAPI
import RuntimeCore

/// The GPU profile of `apkrun dev boot --gpu` (cli.md §5; runtime-api.md §15).
///
/// `none` stays the default of `apkrun dev boot` until the drmVirgl boot is verified on the VM (IR-584).
public enum DevGPUProfile: String, CaseIterable, Sendable {
    /// `none`: the development `headless` profile, where VZ's 2D device is the DRM device (#13).
    case none
    /// `swiftshader`: the `guestSwiftshader` profile, which needs no host renderer (#22).
    case swiftshader
    /// `virgl`: the `drmVirgl` profile, which renders through the VirGL renderer on the host (#23).
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

/// Inputs for `apkrun dev boot` (cli.md §5; #13-#15, #22).
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
    /// A package to launch on display 0 once Android is ready (`apkrun dev launch`, #73). Nil launches nothing.
    public var launchPackage: String?
    /// An optional APK to install before launching `launchPackage` (#27).
    public var launchAPKURL: URL?
    /// App windows launched together by `apkrun dev launch <apk1> <apk2>` (#31).
    public var appLaunches: [DevBootAppLaunch]
    /// The window's connection to display 0 (`apkrun dev boot --window`, #24). Nil shows nothing. It needs `drmVirgl`.
    public var developerDisplay: DeveloperDisplay?
    /// The window that receives app frames. A secondary lease attaches after Android is ready.
    public var windowDisplay: DeveloperDisplay?
    /// The display policy selected by `apkrun dev launch`.
    public var windowDisplayMode: AndroidWindowMode
    /// The development input route of the window (#25). Nil binds no input. It is bound once the Guest Agent is ready,
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
        appLaunches: [DevBootAppLaunch] = [],
        developerDisplay: DeveloperDisplay? = nil,
        inputRoute: DevInputRoute? = nil,
        windowDisplay: DeveloperDisplay? = nil,
        windowDisplayMode: AndroidWindowMode = .primaryDisplayCompatibility
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
        self.appLaunches = appLaunches
        self.developerDisplay = developerDisplay
        self.inputRoute = inputRoute
        self.windowDisplay = windowDisplay ?? developerDisplay
        self.windowDisplayMode = windowDisplayMode
    }
}

/// One app/window pair in an embedded multi-window launch (#31).
public struct DevBootAppLaunch: Sendable {
    /// The Android package to install, launch, and stop for this window.
    public let packageID: String
    /// APK to install before launch, or `nil` when it is already installed.
    public let apkURL: URL?
    /// The native window's IOSurface presenter.
    public let display: DeveloperDisplay
    /// Whether this window uses Android display 0 or a separately leased Android display.
    public let displayMode: AndroidWindowMode
    /// The pointer and key route owned by this window.
    public let inputRoute: DevInputRoute
    /// A close notification from this window only.
    public let closeRequests: AsyncStream<Void>
    /// Local close state used to cancel this window's launch wait without stopping sibling sessions.
    public let windowState: DevBootAppWindowState

    /// Creates one app/window pair.
    public init(
        packageID: String,
        apkURL: URL?,
        display: DeveloperDisplay,
        displayMode: AndroidWindowMode = .secondaryDisplay,
        inputRoute: DevInputRoute,
        closeRequests: AsyncStream<Void>,
        windowState: DevBootAppWindowState = DevBootAppWindowState()
    ) {
        self.packageID = packageID
        self.apkURL = apkURL
        self.display = display
        self.displayMode = displayMode
        self.inputRoute = inputRoute
        self.closeRequests = closeRequests
        self.windowState = windowState
    }
}

/// Tracks whether one development app window has closed.
public actor DevBootAppWindowState {
    private var closed = false

    /// Creates an open app-window state.
    public init() {}

    /// Records that the native window closed.
    public func close() {
        closed = true
    }

    /// Whether the native window has closed.
    public func isClosed() -> Bool {
        closed
    }
}

/// Coordinates per-window close and app-exit behavior while one VM serves several windows.
actor DevBootMultiWindowCoordinator {
    private let launches: [String: DevBootAppLaunch]
    private let stopSignal: DevBootStopSignal
    private let report: @Sendable (DevBootEvent) -> Void
    private var services: [String: EmbeddedRuntimeService] = [:]
    private var closedPackages: Set<String> = []

    init(
        launches: [DevBootAppLaunch],
        stopSignal: DevBootStopSignal,
        report: @escaping @Sendable (DevBootEvent) -> Void
    ) {
        self.launches = Dictionary(uniqueKeysWithValues: launches.map { ($0.packageID, $0) })
        self.stopSignal = stopSignal
        self.report = report
    }

    func register(_ service: EmbeddedRuntimeService, for packageID: String) -> Bool {
        guard !closedPackages.contains(packageID) else {
            return false
        }
        services[packageID] = service
        return true
    }

    func isClosed(_ packageID: String) -> Bool {
        closedPackages.contains(packageID)
    }

    /// Handles a user close by ending input before stopping the app and releasing its display lease.
    func closeWindow(for packageID: String) async {
        guard let launch = launches[packageID], markClosed(packageID) else {
            return
        }
        await launch.windowState.close()
        var stopFailed = false
        if let service = services[packageID] {
            do {
                try await service.closeForWindow()
            } catch {
                report(.warning("could not finish Android tasks for \(packageID): \(error.code)"))
                stopFailed = true
            }
        } else {
            await launch.inputRoute.unbind()
        }
        launch.display.finish()
        if stopFailed {
            // The closed app would otherwise keep a live, invisible session and its display lease.
            // Stop the shared runtime so its common teardown releases every window session.
            await stopSignal.signal(.appWindowCloseFailed)
            return
        }
        await stopIfAllWindowsEnded()
    }

    /// Handles natural app exit without sending a second stop request to Android.
    func appExited(packageID: String) async {
        guard let launch = launches[packageID], markClosed(packageID) else {
            return
        }
        await launch.windowState.close()
        await launch.inputRoute.unbind()
        if let service = services[packageID] {
            _ = try? await service.runtimeStopped()
        }
        launch.display.finish()
        await stopIfAllWindowsEnded()
    }

    /// Closes a window when the guest snapshot shows that its session ended during a reconnect.
    func reconcileTerminalSession(_ session: AppSessionSnapshot) async {
        let packageID = session.packageID
        guard let launch = launches[packageID], markClosed(packageID) else {
            return
        }
        await launch.windowState.close()
        await launch.inputRoute.unbind()
        if let service = services[packageID] {
            _ = try? await service.runtimeStopped()
        }
        launch.display.finish()

        switch session.state {
        case .ended(.appExited):
            break
        case .ended(.error(.displayLost)):
            report(
                .warning(
                    "Android display was lost for \(packageID) during reconnect; close and relaunch its window."
                )
            )
        default:
            report(.warning("Android session for \(packageID) ended during reconnect: \(session.state)."))
        }
        report(.appWindowExited(packageID: packageID))
        await stopIfAllWindowsEnded()
    }

    /// Ends all remaining windows when Ctrl-C stops the shared VM.
    func stopAllWindows() async {
        for (packageID, launch) in launches {
            if markClosed(packageID) {
                await launch.windowState.close()
            }
            if let service = services[packageID] {
                await service.closeForRuntimeStop()
            } else {
                await launch.inputRoute.unbind()
            }
            launch.display.finish()
        }
    }

    private func markClosed(_ packageID: String) -> Bool {
        closedPackages.insert(packageID).inserted
    }

    private func stopIfAllWindowsEnded() async {
        if closedPackages.count == launches.count {
            await stopSignal.signal(.appWindowClosed)
        }
    }
}

/// What `apkrun dev boot` reports while it runs.
public enum DevBootEvent: Sendable {
    /// A runtime state change, as text (`booting(init)`, `ready`, …).
    case state(String)
    /// A short status for the native development-window placeholder.
    case windowStatus(String)
    /// The Android application label for the native development window.
    case windowTitle(String)
    /// The Android app label for one of several native development windows.
    case appWindowTitle(packageID: String, title: String)
    /// A placeholder update for one of several native development windows.
    case appWindowStatus(packageID: String, status: String)
    /// Android finished one app's task; close only its native window.
    case appWindowExited(packageID: String)
    /// Bytes from the kernel console.
    case console(Data)
    /// A one-line status message for the developer.
    case message(String)
    /// A human-readable development warning.
    case warning(String)
    /// A development warning from the error catalog (cliExit 0). It prints with its `hint:` and `code:` lines.
    case catalogWarning(any APKRunError)
}

/// The already-booted development runtime made available to a short embedded operation.
///
/// Package CLI commands use this callback to run through the normal RuntimeHost and package-store
/// path, then return so `DevBoot` can stop Android and release the instance lock.
public struct DevelopmentRuntimeContext: Sendable {
    /// The installed Android image used by this runtime.
    public let image: InstalledImage
    /// The per-user runtime state store.
    public let instanceStore: InstanceStore
    /// The supervisor that owns the active Android runtime.
    public let supervisor: RuntimeSupervisor
    /// The diagnostics context for this embedded run.
    public let diagnostics: DiagnosticsContext
    private let developerDisplay: DeveloperDisplay?
    private let stopSignal: DevBootStopSignal?
    private let existingSession: EmbeddedRuntimeService?
    private let providedSessionService: (any RuntimeSessionService)?

    /// Creates the context passed to one embedded runtime operation.
    public init(
        image: InstalledImage,
        instanceStore: InstanceStore,
        supervisor: RuntimeSupervisor,
        diagnostics: DiagnosticsContext
    ) {
        self.image = image
        self.instanceStore = instanceStore
        self.supervisor = supervisor
        self.diagnostics = diagnostics
        developerDisplay = nil
        stopSignal = nil
        existingSession = nil
        providedSessionService = nil
    }

    init(
        image: InstalledImage,
        instanceStore: InstanceStore,
        supervisor: RuntimeSupervisor,
        diagnostics: DiagnosticsContext,
        developerDisplay: DeveloperDisplay?,
        stopSignal: DevBootStopSignal,
        existingSession: EmbeddedRuntimeService?,
        sessionService: (any RuntimeSessionService)? = nil
    ) {
        self.image = image
        self.instanceStore = instanceStore
        self.supervisor = supervisor
        self.diagnostics = diagnostics
        self.developerDisplay = developerDisplay
        self.stopSignal = stopSignal
        self.existingSession = existingSession
        providedSessionService = sessionService
    }

    /// Creates a display-backed session service when this embedded runtime owns a native window.
    ///
    /// Package operations can use this service to implement RuntimeAPI `launch` and `terminate`
    /// through the same Guest Agent and window session as `apkrun dev launch`.
    public func makeSessionService() async -> (any RuntimeSessionService)? {
        guard let guestAgent = await supervisor.developmentGuestAgent else {
            return nil
        }
        if let providedSessionService {
            if let embedded = providedSessionService as? EmbeddedRuntimeService {
                await embedded.attachGuestAgent(guestAgent)
            }
            if let embedded = providedSessionService as? EmbeddedMultiSessionService {
                await embedded.attachGuestAgent(guestAgent)
            }
            return providedSessionService
        }
        if let existingSession {
            await existingSession.attachGuestAgent(guestAgent)
            return existingSession
        }
        guard let developerDisplay, let stopSignal else { return nil }
        let service = EmbeddedRuntimeService(
            logSink: diagnostics.logSink,
            developerDisplay: developerDisplay,
            stopSignal: stopSignal
        )
        await service.attachGuestAgent(guestAgent)
        return service
    }

    /// Creates a CLI-facing controller for the VM's secondary Android displays.
    ///
    /// This requires a ready boot with both a GraphicsCore device and a Guest Agent connection. RuntimeCore lease
    /// types stay inside RuntimeHost so command-line clients depend only on this facade.
    public func makeDisplayControl() async -> DevelopmentDisplayControl? {
        guard let pool = await supervisor.makeDisplayPool() else {
            return nil
        }
        return DevelopmentDisplayControl(pool: pool)
    }
}

/// Boots the Android image of a development bundle inside the embedded CLI process.
public struct DevBoot: Sendable {
    /// Creates the development boot runner.
    public init() {}

    /// Boots the current image, provisions the instance if needed, and waits for a stop request.
    ///
    /// The instance lock is held for the whole run. The current image is checked quickly before
    /// the boot (android-image.md §9.3). An instance made from another image version is refused,
    /// because migration arrives with #59; `--reset` provisions a new instance instead. Developer
    /// mode is always on: the Android serial shell answers on hvc1, and logcat is captured to
    /// `<logs>/guest/logcat-<timestamp>.log` (android-image.md §7.1).
    public func run(
        options: DevBootOptions,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stopRequests: AsyncStream<Void>,
        appCloseRequests: AsyncStream<Void>? = nil,
        preserveWindowOnError: Bool = false,
        onRuntimeReady: (@Sendable (DevelopmentRuntimeContext) async throws -> (any RuntimeSessionService)?)? = nil,
        onEvent: @escaping @Sendable (DevBootEvent) -> Void
    ) async throws {
        if !options.appLaunches.isEmpty {
            let packages = options.appLaunches.map(\.packageID)
            guard options.launchPackage == nil,
                options.appLaunches.count == 2,
                Set(packages).count == packages.count,
                options.appLaunches.filter({ $0.displayMode == .primaryDisplayCompatibility }).count == 1,
                options.appLaunches.contains(where: { $0.displayMode == .secondaryDisplay })
            else {
                throw RuntimeWireError.runtime(
                    "invalidMultiWindowLaunch",
                    message:
                        "A two-window development launch needs two different packages and one primary plus one secondary display.",
                    remediation: "Pass two distinct APK files or package IDs to `apkrun dev launch`."
                )
            }
        }
        // Every log line of the boot carries one operation ID (AGENTS §8).
        try await OperationContext.withNew {
            try await execute(
                options: options,
                environment: environment,
                stopRequests: stopRequests,
                appCloseRequests: appCloseRequests,
                preserveWindowOnError: preserveWindowOnError,
                onRuntimeReady: onRuntimeReady,
                onEvent: onEvent
            )
        }
    }

    private func execute(
        options: DevBootOptions,
        environment: [String: String],
        stopRequests: AsyncStream<Void>,
        appCloseRequests: AsyncStream<Void>?,
        preserveWindowOnError: Bool,
        onRuntimeReady: (@Sendable (DevelopmentRuntimeContext) async throws -> (any RuntimeSessionService)?)?,
        onEvent: @escaping @Sendable (DevBootEvent) -> Void
    ) async throws {
        var returnedNormally = false
        let windowDisplay = options.windowDisplay ?? options.developerDisplay
        defer {
            if !preserveWindowOnError || returnedNormally {
                windowDisplay?.finish()
            }
        }
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
        let stopSignal = DevBootStopSignal()
        var embeddedSession: EmbeddedRuntimeService?
        let logcat = try LogcatFile(directory: paths.logsRoot.appendingPathComponent("guest", isDirectory: true))
        onEvent(.message("logcat goes to \(logcat.url.path)"))
        let consoles = DevConsoleSocketServer(directory: paths.devConsoleDirectory)
        let eventTask = Task {
            for await event in supervisor.events {
                switch event {
                case .state(let snapshot):
                    onEvent(.state(Self.describe(snapshot.state)))
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

        await stopSignal.attachStopHandler { await supervisor.stop() }
        let multiWindowCoordinator: DevBootMultiWindowCoordinator? =
            options.appLaunches.isEmpty
            ? nil
            : DevBootMultiWindowCoordinator(
                launches: options.appLaunches,
                stopSignal: stopSignal,
                report: onEvent
            )
        let appWindowCloseMonitors =
            multiWindowCoordinator.map {
                Self.observeAppWindowCloseRequests(launches: options.appLaunches, coordinator: $0)
            } ?? []
        let stopRequestMonitor = Self.observeStopRequests(
            stopRequests: stopRequests,
            appCloseRequests: appCloseRequests,
            signal: stopSignal
        )
        var taskEventMonitor: Task<Void, Never>?
        var multiWindowServices: [String: EmbeddedRuntimeService] = [:]
        var runtimeSessionService: (any RuntimeSessionService)?
        defer {
            stopRequestMonitor.cancel()
            taskEventMonitor?.cancel()
            for monitor in appWindowCloseMonitors {
                monitor.cancel()
            }
        }
        var stopCause: StopCause = .signal
        let started = ContinuousClock.now
        if await stopSignal.current() == nil {
            if windowDisplay != nil {
                onEvent(.windowStatus("Starting Android…"))
            }
            do {
                try await supervisor.ensureReady(.cli)
                if await stopSignal.current() == nil {
                    onEvent(.message("Android is ready after \(ContinuousClock.now - started)"))
                    if windowDisplay != nil, options.launchPackage != nil {
                        onEvent(.windowStatus("Preparing app…"))
                    }
                    if let package = options.launchPackage, let windowDisplay {
                        guard let displayPool = await supervisor.makeDisplayPool() else {
                            throw RuntimeWireError.runtime(
                                "displayAttachFailed",
                                message: "APKRun couldn't prepare the Android display pool.",
                                remediation: "Restart Android with the development Guest Agent and graphics enabled."
                            )
                        }
                        let service = EmbeddedRuntimeService(
                            logSink: diagnostics.logSink,
                            developerDisplay: windowDisplay,
                            stopSignal: stopSignal,
                            displayPool: displayPool,
                            inputRoute: options.inputRoute
                        )
                        if await stopSignal.beginDisplayAcquisition() {
                            let mode = windowDisplay.mode
                            let renderScale = max(mode.renderScale, 0.01)
                            let configuration = DisplayConfiguration(
                                geometry: DisplayGeometry(
                                    pointSize: CGSize(
                                        width: Double(mode.pixelSize.width) / renderScale,
                                        height: Double(mode.pixelSize.height) / renderScale
                                    ),
                                    backingScale: Double(windowDisplay.backingScale),
                                    zoom: mode.zoom
                                ),
                                mode: options.windowDisplayMode
                            )
                            _ = try await service.requestLeasedSession(
                                packageID: package,
                                configuration: configuration
                            )
                            embeddedSession = service
                        }
                    }
                    if !options.appLaunches.isEmpty, await stopSignal.current() == nil {
                        guard let displayPool = await supervisor.makeDisplayPool() else {
                            throw RuntimeWireError.runtime(
                                "displayAttachFailed",
                                message: "APKRun couldn't prepare the Android display pool.",
                                remediation: "Restart Android with the development Guest Agent and graphics enabled."
                            )
                        }
                        let registry = SessionRegistry(logSink: diagnostics.logSink)
                        guard let coordinator = multiWindowCoordinator else {
                            throw RuntimeWireError.runtime(
                                "internal",
                                message: "The multi-window coordinator is unavailable.",
                                remediation: "Restart the development launch."
                            )
                        }
                        guard let agent = await supervisor.developmentGuestAgent else {
                            throw GuestAgentFailure.startFailed
                        }
                        for launch in options.appLaunches {
                            guard await stopSignal.current() == nil,
                                await !launch.windowState.isClosed(),
                                await stopSignal.beginDisplayAcquisition()
                            else {
                                continue
                            }
                            let service = EmbeddedRuntimeService(
                                registry: registry,
                                logSink: diagnostics.logSink,
                                developerDisplay: launch.display,
                                stopSignal: stopSignal,
                                displayPool: displayPool,
                                inputRoute: launch.inputRoute,
                                windowState: launch.windowState,
                                onTerminalSessionReconciled: { session in
                                    await coordinator.reconcileTerminalSession(session)
                                }
                            )
                            await service.attachGuestAgent(agent)
                            _ = try await service.requestLeasedSession(
                                packageID: launch.packageID,
                                configuration: Self.displayConfiguration(for: launch)
                            )
                            guard await coordinator.register(service, for: launch.packageID) else {
                                try? await service.closeForWindow()
                                launch.display.finish()
                                continue
                            }
                            multiWindowServices[launch.packageID] = service
                        }
                        if !multiWindowServices.isEmpty {
                            let multiSessionService = EmbeddedMultiSessionService(sessions: multiWindowServices)
                            runtimeSessionService = multiSessionService
                            if let onRuntimeReady {
                                runtimeSessionService =
                                    try await onRuntimeReady(
                                        DevelopmentRuntimeContext(
                                            image: image,
                                            instanceStore: store,
                                            supervisor: supervisor,
                                            diagnostics: diagnostics,
                                            developerDisplay: windowDisplay,
                                            stopSignal: stopSignal,
                                            existingSession: nil,
                                            sessionService: multiSessionService
                                        )
                                    ) ?? multiSessionService
                            }
                        }
                        onEvent(.message("prepared \(multiWindowServices.count) app display session(s)"))
                    }
                    if await stopSignal.current() == nil, let onRuntimeReady {
                        if options.appLaunches.isEmpty {
                            runtimeSessionService = try await onRuntimeReady(
                                DevelopmentRuntimeContext(
                                    image: image,
                                    instanceStore: store,
                                    supervisor: supervisor,
                                    diagnostics: diagnostics,
                                    developerDisplay: windowDisplay,
                                    stopSignal: stopSignal,
                                    existingSession: embeddedSession
                                )
                            )
                        }
                    }
                }
            } catch {
                guard let requestedStop = await stopSignal.current() else {
                    await multiWindowCoordinator?.stopAllWindows()
                    await stopSignal.stopRuntime()
                    throw error
                }
                stopCause = requestedStop
            }
        }
        // The window's input reaches its leased Android display through the Guest Agent (#25, #30).
        var inputBinding: Task<Void, Never>?
        do {
            if let requestedStop = await stopSignal.current() {
                stopCause = requestedStop
            } else if let embeddedSession {
                _ = try await embeddedSession.displayReady()
            }
            if await stopSignal.current() == nil, !multiWindowServices.isEmpty {
                if let agent = await supervisor.developmentGuestAgent {
                    let activeRoutes = options.appLaunches
                        .filter { multiWindowServices[$0.packageID] != nil }
                        .map(\.inputRoute)
                    let binding = DevInputBinding(routes: activeRoutes, agent: agent, logSink: diagnostics.logSink)
                    inputBinding = Task { await binding.run(report: onEvent) }
                } else {
                    onEvent(.catalogWarning(RuntimeFailure.inputNotBound(cause: nil)))
                }
            } else if await stopSignal.current() == nil, let route = options.inputRoute {
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
                let mayLaunch: Bool
                if let apkURL = options.launchAPKURL {
                    mayLaunch = try await Self.installAPKAndBeginLaunch(stopSignal: stopSignal) {
                        onEvent(.windowStatus("Installing app…"))
                        try await agent.installAPK(apkURL, package: package)
                    }
                } else {
                    mayLaunch = await stopSignal.beginLaunch()
                }
                if mayLaunch, windowDisplay != nil {
                    let displayName: String
                    do {
                        let packageInfo = try await agent.queryPackage(package)
                        let label = packageInfo?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        displayName = label.isEmpty ? package : label
                    } catch {
                        displayName = package
                    }
                    onEvent(.windowTitle(displayName))
                }
                if mayLaunch, let embeddedSession {
                    await embeddedSession.attachGuestAgent(agent)
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
                }
                if mayLaunch, await stopSignal.current() == nil {
                    if windowDisplay != nil {
                        onEvent(.windowStatus("Starting app…"))
                    }
                    if let embeddedSession {
                        guard let packageID = RuntimePackageID(rawValue: package) else {
                            throw RuntimeWireError.runtime(
                                "internal",
                                message: "The Android package identifier is invalid.",
                                remediation: "Check the package name and try again."
                            )
                        }
                        let request = RuntimeLaunchRequest(packageID: packageID)
                        let result: RuntimeLaunchResult
                        if let runtimeSessionService {
                            result = try await runtimeSessionService.launch(request)
                        } else {
                            result = try await embeddedSession.launch(request)
                        }
                        if await embeddedSession.currentSession()?.state == .ended(.appExited) {
                            await stopSignal.signal(.appExited)
                        }
                        let displayID = (await embeddedSession.currentSession())?.displayID ?? 0
                        onEvent(
                            .message("launched \(package) on display \(displayID) (session state: \(result.state))")
                        )
                    } else {
                        let report = try await agent.launch(package: package, displayID: 0)
                        onEvent(
                            .message(
                                "launched \(package) on display 0: task \(report.taskID) \(report.component) (\(report.outcome))"
                            )
                        )
                    }
                    if let requestedStop = await stopSignal.current() {
                        stopCause = requestedStop
                    }
                }
            }
            if !multiWindowServices.isEmpty,
                await stopSignal.current() == nil,
                let agent = await supervisor.developmentGuestAgent,
                let coordinator = multiWindowCoordinator
            {
                taskEventMonitor = Self.observeMultiWindowTaskEvents(
                    agent: agent,
                    services: multiWindowServices,
                    coordinator: coordinator,
                    onEvent: onEvent
                )
                for launch in options.appLaunches {
                    guard let service = multiWindowServices[launch.packageID],
                        await !launch.windowState.isClosed(),
                        await stopSignal.current() == nil
                    else {
                        continue
                    }
                    if let apkURL = launch.apkURL {
                        let mayLaunch = try await Self.installAPKAndBeginLaunch(stopSignal: stopSignal) {
                            onEvent(.appWindowStatus(packageID: launch.packageID, status: "Installing app…"))
                            try await agent.installAPK(apkURL, package: launch.packageID)
                        }
                        guard mayLaunch,
                            await !launch.windowState.isClosed(),
                            await stopSignal.current() == nil
                        else {
                            continue
                        }
                    } else {
                        guard await stopSignal.beginLaunch() else {
                            continue
                        }
                    }
                    do {
                        let packageInfo = try await agent.queryPackage(launch.packageID)
                        let label = packageInfo?.label.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        onEvent(
                            .appWindowTitle(
                                packageID: launch.packageID,
                                title: label.isEmpty ? launch.packageID : label
                            )
                        )
                    } catch {
                        onEvent(.appWindowTitle(packageID: launch.packageID, title: launch.packageID))
                    }
                    onEvent(.appWindowStatus(packageID: launch.packageID, status: "Starting app…"))
                    do {
                        let packageID = try Self.runtimePackageID(launch.packageID)
                        let result: RuntimeLaunchResult
                        if let runtimeSessionService {
                            result = try await runtimeSessionService.launch(
                                RuntimeLaunchRequest(packageID: packageID)
                            )
                        } else {
                            result = try await service.launch(RuntimeLaunchRequest(packageID: packageID))
                        }
                        if await launch.windowState.isClosed() {
                            continue
                        }
                        let displayID = (await service.currentSession())?.displayID ?? 0
                        onEvent(
                            .message(
                                "launched \(launch.packageID) on display \(displayID) (session state: \(result.state))"
                            )
                        )
                        if await service.currentSession()?.state == .ended(.appExited) {
                            await coordinator.appExited(packageID: launch.packageID)
                            onEvent(.appWindowExited(packageID: launch.packageID))
                        }
                    } catch {
                        if await launch.windowState.isClosed() {
                            continue
                        }
                        throw error
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
                await endInput(inputBinding, routes: Self.inputRoutes(options))
                await multiWindowCoordinator?.stopAllWindows()
                await stopSignal.stopRuntime()
                throw error
            }
            await endInput(inputBinding, routes: Self.inputRoutes(options))
        }
        // The counters of the route are read before the route is unbound, which discards its router (input.md §11).
        if let route = options.inputRoute {
            onEvent(.message("input counters: \(await route.counters())"))
        }
        if let agent = await supervisor.developmentGuestAgent {
            onEvent(.message("ADB shell invocations so far: \(await agent.adbShellInvocationCount)"))
        }
        onEvent(.message("stopping Android"))
        await endInput(inputBinding, routes: Self.inputRoutes(options))
        await multiWindowCoordinator?.stopAllWindows()
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
        _ = try? await embeddedSession?.runtimeStopped()
        await stopSignal.stopRuntime()
        returnedNormally = true
    }

    private static func displayConfiguration(for launch: DevBootAppLaunch) -> DisplayConfiguration {
        let mode = launch.display.mode
        let renderScale = max(mode.renderScale, 0.01)
        return DisplayConfiguration(
            geometry: DisplayGeometry(
                pointSize: CGSize(
                    width: Double(mode.pixelSize.width) / renderScale,
                    height: Double(mode.pixelSize.height) / renderScale
                ),
                backingScale: Double(launch.display.backingScale),
                zoom: mode.zoom
            ),
            mode: launch.displayMode
        )
    }

    private static func inputRoutes(_ options: DevBootOptions) -> [DevInputRoute] {
        options.appLaunches.map(\.inputRoute) + [options.inputRoute].compactMap { $0 }
    }

    /// Starts close monitors before VM readiness, so closing both launch windows cancels a long Android boot.
    static func observeAppWindowCloseRequests(
        launches: [DevBootAppLaunch],
        coordinator: DevBootMultiWindowCoordinator
    ) -> [Task<Void, Never>] {
        launches.map { launch in
            Task {
                for await _ in launch.closeRequests {
                    await coordinator.closeWindow(for: launch.packageID)
                    return
                }
            }
        }
    }

    private static func runtimePackageID(_ package: String) throws(RuntimeWireError) -> RuntimePackageID {
        guard let packageID = RuntimePackageID(rawValue: package) else {
            throw .runtime(
                "invalidPackageID",
                message: "The Android package identifier is invalid.",
                remediation: "Check the package name and try again."
            )
        }
        return packageID
    }

    private static func observeMultiWindowTaskEvents(
        agent: DevelopmentGuestAgent,
        services: [String: EmbeddedRuntimeService],
        coordinator: DevBootMultiWindowCoordinator,
        onEvent: @escaping @Sendable (DevBootEvent) -> Void
    ) -> Task<Void, Never> {
        Task {
            for await event in agent.taskEvents {
                let packageID: String
                switch event {
                case .appeared(let value, _), .vanished(let value, _):
                    packageID = value
                }
                guard let service = services[packageID],
                    let snapshot = await service.taskEvent(event),
                    snapshot.state == .ended(.appExited)
                else {
                    continue
                }
                await coordinator.appExited(packageID: packageID)
                onEvent(.appWindowExited(packageID: packageID))
            }
        }
    }

    static func installAPKAndBeginLaunch(
        stopSignal: DevBootStopSignal,
        install: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        guard await stopSignal.beginPackageInstall() else {
            return false
        }
        try await install()
        return await stopSignal.beginLaunch()
    }

    enum StopCause: Sendable, Equatable {
        case signal
        case appWindowClosed
        case appExited
        case appWindowCloseFailed
    }

    enum FrameWaitResult: Sendable, Equatable {
        case presented
        case timedOut
        case stopped(StopCause)
        case windowClosed
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
        windowState: DevBootAppWindowState? = nil,
        timeout: Duration = .seconds(15),
        pollInterval: Duration = .milliseconds(50)
    ) async -> FrameWaitResult {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await windowState?.isClosed() == true {
                return .windowClosed
            }
            if let cause = await stopSignal.current() {
                return .stopped(cause)
            }
            if display.windowFrameCommitCount > sequence {
                return .presented
            }
            try? await Task.sleep(for: pollInterval)
        }
        if await windowState?.isClosed() == true {
            return .windowClosed
        }
        if let cause = await stopSignal.current() {
            return .stopped(cause)
        }
        return .timedOut
    }

    /// Stops the input binding, and unbinds the route. The unbinding sends `cancelAll` while the agent still runs, so
    /// the guest releases every gesture and button that is open (input.md §7.3, #25).
    private func endInput(_ binding: Task<Void, Never>?, route: DevInputRoute?) async {
        await endInput(binding, routes: [route].compactMap { $0 })
    }

    private func endInput(_ binding: Task<Void, Never>?, routes: [DevInputRoute]) async {
        binding?.cancel()
        await binding?.value
        for route in routes {
            await route.unbind()
        }
    }

    static func describe(_ state: RuntimeState) -> String {
        switch state {
        case .stopped: "stopped"
        case .booting(let phase): "booting(\(phase))"
        case .ready: "ready"
        case .stopping(_): "stopping"
        case .failed(let failure): "failed(\(failure.qualifiedCode))"
        }
    }
}

actor DevBootStopSignal {
    private var cause: DevBoot.StopCause?
    private var waiter: CheckedContinuation<DevBoot.StopCause, Never>?
    private var applicationOperationStarted = false
    private var stopHandler: (@Sendable () async -> Void)?
    private var stopTask: Task<Void, Never>?

    func attachStopHandler(_ handler: @escaping @Sendable () async -> Void) {
        stopHandler = handler
        if let cause, shouldStopRuntimeImmediately(for: cause) {
            scheduleStop(using: handler)
        }
    }

    func beginPackageInstall() -> Bool {
        guard cause == nil else {
            return false
        }
        applicationOperationStarted = true
        return true
    }

    func beginDisplayAcquisition() -> Bool {
        guard cause == nil else {
            return false
        }
        applicationOperationStarted = true
        return true
    }

    func beginLaunch() -> Bool {
        guard cause == nil else {
            return false
        }
        applicationOperationStarted = true
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

    func hasScheduledRuntimeStop() -> Bool {
        stopTask != nil
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
        case .appWindowClosed, .appWindowCloseFailed:
            !applicationOperationStarted
        case .signal:
            !applicationOperationStarted
        case .appExited:
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

/// Where the development Guest Agent bundle is (guest-components.md §2, build-system.md §7.1). The order is the
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
