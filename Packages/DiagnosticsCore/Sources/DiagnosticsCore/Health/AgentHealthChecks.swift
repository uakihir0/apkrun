import Foundation

/// The guest-side counters a `GetHealth` call returns, reduced to what the
/// health checks read (diagnostics.md §7.4). RuntimeCore maps `GPHealth` onto
/// this so DiagnosticsCore never imports the wire schema.
public struct AgentHealthSnapshot: Sendable, Equatable {
    /// Agent uptime in milliseconds.
    public let agentUptimeMs: UInt64
    /// Whether the agent runs as a development shell or a privileged app.
    public let isDevelopmentShell: Bool
    /// Number of live Android displays.
    public let displaysCount: Int
    /// Whether the APKRun input method is selected.
    public let imeSelected: Bool
    /// Whether the notification listener is enabled.
    public let notificationListenerEnabled: Bool
    /// Whether ADB is enabled in the guest.
    public let adbEnabled: Bool
    /// Total guest memory in KiB.
    public let memoryTotalKb: UInt64
    /// Available guest memory in KiB.
    public let memoryAvailableKb: UInt64
    /// Whether the guest reports low memory.
    public let lowMemory: Bool
    /// Input batches injected so far.
    public let inputBatches: UInt64
    /// Input events injected so far.
    public let inputEventsInjected: UInt64
    /// Input events the guest rejected.
    public let inputEventsRejected: UInt64

    /// Creates a snapshot.
    public init(
        agentUptimeMs: UInt64,
        isDevelopmentShell: Bool,
        displaysCount: Int,
        imeSelected: Bool,
        notificationListenerEnabled: Bool,
        adbEnabled: Bool,
        memoryTotalKb: UInt64,
        memoryAvailableKb: UInt64,
        lowMemory: Bool,
        inputBatches: UInt64,
        inputEventsInjected: UInt64,
        inputEventsRejected: UInt64
    ) {
        self.agentUptimeMs = agentUptimeMs
        self.isDevelopmentShell = isDevelopmentShell
        self.displaysCount = displaysCount
        self.imeSelected = imeSelected
        self.notificationListenerEnabled = notificationListenerEnabled
        self.adbEnabled = adbEnabled
        self.memoryTotalKb = memoryTotalKb
        self.memoryAvailableKb = memoryAvailableKb
        self.lowMemory = lowMemory
        self.inputBatches = inputBatches
        self.inputEventsInjected = inputEventsInjected
        self.inputEventsRejected = inputEventsRejected
    }
}

/// How the agent.* and graphics.* checks reach the guest and the daemon. The
/// runtime host owns the connections; DiagnosticsCore only sees these reads so
/// one `GetHealth` round trip feeds every check in a report (§7.4).
public protocol HealthDataProbe: Sendable {
    /// The guest's health snapshot, or nil when the agent cannot be reached.
    func agentHealth() async -> AgentHealthSnapshot?

    /// Whether the apkrund broker answers a hello on the same API major.
    func daemonReachable() async -> Bool

    /// The build the running apkrund reports, or nil when unreachable.
    func daemonBuild() async -> String?

    /// Unclean apkrund exits in the last 10 minutes (crash reports or daemon
    /// accounting).
    func daemonCrashCount() async -> Int

    /// Graphics counters of the running VM, or nil when nothing runs.
    func graphicsStatus() async -> GraphicsHealthStatus?
}

/// The graphics facts the graphics.* checks read (diagnostics.md §7.4).
public struct GraphicsHealthStatus: Sendable, Equatable {
    /// Whether the virtio-gpu device finished setup.
    public let deviceReady: Bool
    /// Whether rendering runs on the GPU (false: software rendering).
    public let gpuRendering: Bool
    /// Whether frames present on the fast IOSurface path.
    public let fastPresentation: Bool
    /// Whether the graphics memory limit was hit.
    public let memoryLimitReached: Bool
    /// Whether graphics safe mode is enabled.
    public let safeMode: Bool

    /// Creates a graphics status snapshot.
    public init(
        deviceReady: Bool,
        gpuRendering: Bool,
        fastPresentation: Bool,
        memoryLimitReached: Bool,
        safeMode: Bool
    ) {
        self.deviceReady = deviceReady
        self.gpuRendering = gpuRendering
        self.fastPresentation = fastPresentation
        self.memoryLimitReached = memoryLimitReached
        self.safeMode = safeMode
    }
}

/// The §7.4 `agent.*`, `graphics.*`, and `apkrund.*` check catalogue.
public enum HealthChecks {

    /// Catalog-backed error details for a check failure.
    private static func err(_ code: String) -> ErrorInfo {
        let entry = ErrorCatalog.entry(for: code) ?? ErrorCatalog.unknownEntry
        let message = LocalizedText(
            key: code,
            fallback: entry.message?["en"] ?? "The check failed."
        )
        let remediation = entry.remediation?["en"].map {
            LocalizedText(key: "\(code).remediation", fallback: $0)
        }
        return ErrorInfo(
            code: code, message: message, remediation: remediation, action: entry.action)
    }

    /// Registers every check the shared `HealthDataProbe` can feed.
    ///
    /// The probe is asked once per report run for the guest snapshot: the
    /// agent.* and graphics.* checks share that single round trip (§7.4).
    public static func register(
        in registry: HealthCheckRegistry,
        probe: any HealthDataProbe,
        fixes: [HealthCheckID: any HealthFix] = [:]
    ) async throws {
        // A single fetch per report: the probe is queried lazily by the first
        // check that runs and the answer is shared. `HealthCheckPermitPool`
        // bounds concurrency, so a small serial box is enough.
        let shared = SharedAgentHealth(probe: probe)

        func check(
            _ id: HealthCheckID, _ group: HealthGroup, _ title: String,
            requirement: HealthRequirement, cost: HealthCost = .quick,
            measure: @escaping @Sendable (HealthContext) async -> ClosureHealthCheck.HealthOutcome
        ) -> ClosureHealthCheck {
            ClosureHealthCheck(
                id: id, group: group, requirement: requirement, cost: cost,
                title: LocalizedText(key: "health.\(id)", fallback: title),
                fix: fixes[id], measure: measure)
        }

        let checks: [ClosureHealthCheck] = [
            // apkrund.* (§7.3)
            check(
                "apkrund.reachable", .backgroundService, "Background service is reachable",
                requirement: .host
            ) { _ in
                await probe.daemonReachable()
                    ? .init(state: .pass)
                    : .init(state: .failure, error: err("runtime.serviceUnavailable"))
            },
            check(
                "apkrund.version", .backgroundService, "Background service version",
                requirement: .daemon
            ) { context in
                guard let build = await probe.daemonBuild() else {
                    return .init(state: .skipped)
                }
                return build == context.buildInfo.buildNumber
                    ? .init(state: .pass, detail: "build \(build)")
                    : .init(
                        state: .warning,
                        detail: "daemon \(build), app \(context.buildInfo.buildNumber)",
                        error: err("diagnostics.componentVersionMismatch"))
            },
            check(
                "apkrund.crashLoop", .backgroundService, "Background service stability",
                requirement: .host
            ) { _ in
                let crashes = await probe.daemonCrashCount()
                return crashes < 3
                    ? .init(state: .pass)
                    : .init(
                        state: .failure,
                        detail: "\(crashes) unclean exits in 10 minutes",
                        error: err("diagnostics.crashLoop"))
            },
            // graphics.* (§7.4)
            check(
                "graphics.device", .graphics, "Virtual GPU device",
                requirement: .runningRuntime
            ) { _ in
                guard let status = await probe.graphicsStatus() else {
                    return .init(state: .skipped)
                }
                return status.deviceReady
                    ? .init(state: .pass)
                    : .init(state: .failure, error: err("graphics.deviceSetupFailed"))
            },
            check(
                "graphics.renderer", .graphics, "Graphics renderer",
                requirement: .runningRuntime
            ) { _ in
                guard let status = await probe.graphicsStatus() else {
                    return .init(state: .skipped)
                }
                return status.gpuRendering
                    ? .init(state: .pass)
                    : .init(state: .warning, error: err("graphics.softwareRendering"))
            },
            check(
                "graphics.present", .graphics, "Frame presentation",
                requirement: .runningRuntime
            ) { _ in
                guard let status = await probe.graphicsStatus() else {
                    return .init(state: .skipped)
                }
                return status.fastPresentation
                    ? .init(state: .pass)
                    : .init(state: .warning, error: err("graphics.presentationSlowPath"))
            },
            check(
                "graphics.memory", .graphics, "Graphics memory",
                requirement: .runningRuntime
            ) { _ in
                guard let status = await probe.graphicsStatus() else {
                    return .init(state: .skipped)
                }
                return status.memoryLimitReached
                    ? .init(state: .warning, error: err("graphics.memoryLimitReached"))
                    : .init(state: .pass)
            },
            check(
                "graphics.safeMode", .graphics, "Graphics safe mode",
                requirement: .host
            ) { _ in
                guard let status = await probe.graphicsStatus() else {
                    return .init(state: .skipped)
                }
                return status.safeMode
                    ? .init(state: .warning, error: err("graphics.safeModeOn"))
                    : .init(state: .pass)
            },
            check(
                "graphics.guestDriver", .graphics, "Guest graphics driver",
                requirement: .runningRuntime, cost: .deep
            ) { _ in
                guard let status = await probe.graphicsStatus() else {
                    return .init(state: .skipped)
                }
                return status.gpuRendering
                    ? .init(state: .pass)
                    : .init(state: .warning, error: err("graphics.softwareRendering"))
            },
            // agent.* (§7.4) — all share one GetHealth round trip.
            check(
                "agent.guest", .guest, "Guest Agent is answering",
                requirement: .runningRuntime
            ) { _ in
                guard let health = await shared.fetch() else {
                    return .init(state: .failure, error: err("runtime.serviceUnavailable"))
                }
                return .init(
                    state: .pass,
                    detail: "uptime \(health.agentUptimeMs / 1000)s, \(health.displaysCount) display(s)")
            },
            check(
                "agent.store", .guest, "Store Agent is answering",
                requirement: .runningRuntime
            ) { _ in
                // The Store Agent shares the guest channel today; its own
                // channel arrives with the store work. Reaching the Guest
                // Agent is the best available signal.
                await shared.fetch() != nil
                    ? .init(state: .pass)
                    : .init(state: .skipped)
            },
            check(
                "agent.input", .guest, "Input injection",
                requirement: .runningRuntime
            ) { _ in
                guard let health = await shared.fetch() else {
                    return .init(state: .skipped)
                }
                let rejected = health.inputEventsRejected
                let injected = health.inputEventsInjected
                let degraded = rejected > 0 && rejected * 20 > injected + rejected
                return degraded
                    ? .init(
                        state: .warning,
                        detail: "\(rejected) of \(injected + rejected) events rejected",
                        error: err("runtime.inputDegraded"))
                    : .init(state: .pass)
            },
            check(
                "agent.ime", .guest, "APKRun input method selected",
                requirement: .runningRuntime
            ) { _ in
                guard let health = await shared.fetch() else {
                    return .init(state: .skipped)
                }
                return health.imeSelected
                    ? .init(state: .pass)
                    : .init(state: .warning, error: err("runtime.inputMethodNotSelected"))
            },
            check(
                "agent.developerMode", .guest, "Development interfaces",
                requirement: .runningRuntime
            ) { _ in
                guard let health = await shared.fetch() else {
                    return .init(state: .skipped)
                }
                let unexpectedADB = health.adbEnabled && !health.isDevelopmentShell
                return unexpectedADB
                    ? .init(state: .warning, error: err("runtime.adbEnabledUnexpectedly"))
                    : .init(state: .pass)
            },
        ]
        for one in checks {
            try await registry.register(one)
        }
    }
}

/// Shares one `agentHealth()` call between all checks of a report run. The
/// answer lives only for a few seconds: a re-run of the checks must ask the
/// guest again, or a disconnect, recovery, or IME change would never show.
private actor SharedAgentHealth {
    private let probe: any HealthDataProbe
    private let validity: TimeInterval
    private var cached: AgentHealthSnapshot??
    private var cachedAt: Date?
    private var inFlight: Task<AgentHealthSnapshot?, Never>?

    init(probe: any HealthDataProbe, validity: TimeInterval = 5) {
        self.probe = probe
        self.validity = validity
    }

    func fetch() async -> AgentHealthSnapshot? {
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < validity {
            return cached
        }
        if let inFlight { return await inFlight.value }
        let task = Task { await probe.agentHealth() }
        inFlight = task
        let value = await task.value
        cached = value
        cachedAt = Date()
        inFlight = nil
        return value
    }
}
