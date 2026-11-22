import DiagnosticsCore
import Foundation
import GuestProtocol
import RuntimeAPI
import RuntimeCore

/// Feeds the §7.4 `agent.*`, `graphics.*`, and `apkrund.*` checks from the
/// daemon's own connections. One `agentHealth()` round trip is shared by
/// every agent check in a report (diagnostics.md §7.4).
struct RuntimeHostHealthProbe: HealthDataProbe {
    /// The owning host; reads go through the actor.
    let host: RuntimeHost

    func agentHealth() async -> AgentHealthSnapshot? {
        await host.guestHealthSnapshot()
    }

    func daemonReachable() async -> Bool {
        // The probe runs inside apkrund: reaching this code means the broker
        // answered the XPC request.
        true
    }

    func daemonBuild() async -> String? {
        await host.daemonBuildNumber
    }

    func daemonCrashCount() async -> Int {
        await host.recentUncleanExitCount
    }

    func graphicsStatus() async -> GraphicsHealthStatus? {
        await host.graphicsHealthStatus()
    }
}

extension RuntimeHost {
    /// Registers the §7.4 agent/graphics/apkrund catalogue once.
    private func ensureAgentHealthChecksRegistered(fixes: [HealthCheckID: any HealthFix]) async {
        guard !agentHealthChecksRegistered, let registry = healthCheckRegistry else { return }
        agentHealthChecksRegistered = true
        try? await HealthChecks.register(
            in: registry,
            probe: RuntimeHostHealthProbe(host: self),
            fixes: fixes
        )
    }

    /// The guest health snapshot for `apkrun doctor` (diagnostics.md §7.4).
    func guestHealthSnapshot() async -> AgentHealthSnapshot? {
        guard let agent = await supervisor?.developmentGuestAgent else { return nil }
        guard let health = try? await agent.health() else { return nil }
        return AgentHealthSnapshot(
            agentUptimeMs: health.agentUptimeMs,
            isDevelopmentShell: health.mode == .developmentShell,
            displaysCount: Int(health.displaysCount),
            imeSelected: health.imeSelected,
            notificationListenerEnabled: health.notificationListenerEnabled,
            adbEnabled: health.adbEnabled,
            memoryTotalKb: health.memory.totalKb,
            memoryAvailableKb: health.memory.availableKb,
            lowMemory: health.memory.lowMemory,
            inputBatches: health.input.batches,
            inputEventsInjected: health.input.eventsInjected,
            inputEventsRejected: health.input.eventsRejected
        )
    }

    /// The daemon's own build number, for `apkrund.version`.
    var daemonBuildNumber: String? {
        buildInfo.buildNumber
    }

    /// Unclean exits in the last 10 minutes, for `apkrund.crashLoop`.
    var recentUncleanExitCount: Int {
        let cutoff = Date().addingTimeInterval(-DaemonStateStore.crashLoopWindow)
        return startupAssessment?.record.recentUncleanExits
            .filter { $0 >= cutoff }.count ?? 0
    }

    /// The graphics facts the graphics.* checks read, or nil when the VM is
    /// down (the checks are `.runningRuntime` and report `skipped` anyway).
    func graphicsHealthStatus() async -> GraphicsHealthStatus? {
        guard supervisor != nil else { return nil }
        let safeMode =
            (GlobalSettings.load(from: paths.settingsFile)
                .extraValue("graphics.safeMode") ?? "false") == "true"
        let sessions = await sessionGraphicsStatistics(sessionID: nil)
        return GraphicsHealthStatus(
            deviceReady: true,
            gpuRendering: !safeMode,
            fastPresentation: sessions.contains { $0.fps > 0 },
            memoryLimitReached: false,
            safeMode: safeMode
        )
    }

    /// Builds the context the health checks see from this daemon.
    private func healthContext() -> HealthContext {
        HealthContext(
            daemonAvailable: true,
            runtimeRunning: supervisor != nil,
            lastKnown: healthLastKnown,
            buildInfo: buildInfo,
            paths: paths
        )
    }

    /// `healthReport` (runtime-api.md §13). `checks` nil runs every check;
    /// an unknown ID fails with `diagnostics.unknownHealthCheck`.
    func healthReport(
        deep: Bool, checks requested: [String]?
    ) async throws(RuntimeWireError) -> WireHealthReport {
        await ensureAgentHealthChecksRegistered(fixes: healthFixes())
        guard let registry = healthCheckRegistry else {
            throw RuntimeWireError(
                domain: "runtime", code: "runtime.serviceUnavailable",
                message: "The diagnostics registry is unavailable.")
        }
        let context = healthContext()
        var results = await registry.run(deep: deep, context: context)
        if let requested {
            let known = Set(await registry.checkIDs())
            if let unknown = requested.first(where: { !known.contains($0) }) {
                throw RuntimeWireError(
                    domain: "diagnostics", code: "diagnostics.unknownHealthCheck",
                    message: "Unknown health check: \(unknown)")
            }
            let wanted = Set(requested)
            results = results.filter { wanted.contains($0.id) }
        }
        publishHealthChanges(results)
        return Self.wireReport(
            results, verdictContext: healthVerdictContext(), fixed: [])
    }

    /// `applyHealthFixes` (runtime-api.md §13): runs the safe repairs of the
    /// named failed checks (or every fixable failure) and reports again.
    func applyHealthFixes(checks requested: [String]) async throws(RuntimeWireError)
        -> WireHealthReport
    {
        await ensureAgentHealthChecksRegistered(fixes: healthFixes())
        guard let registry = healthCheckRegistry else {
            throw RuntimeWireError(
                domain: "runtime", code: "runtime.serviceUnavailable",
                message: "The diagnostics registry is unavailable.")
        }
        let context = healthContext()
        let results = await registry.run(deep: false, context: context)
        let failed = results.filter { $0.state == .failure }
        let targets =
            requested.isEmpty
            ? failed
            : failed.filter { requested.contains($0.id) }
        guard let first = targets.first else {
            if let named = requested.first,
                !results.contains(where: { $0.id == named })
            {
                throw RuntimeWireError(
                    domain: "diagnostics", code: "diagnostics.unknownHealthCheck",
                    message: "Unknown health check: \(named)")
            }
            throw RuntimeWireError(
                domain: "diagnostics", code: "diagnostics.fixNotAvailable",
                message: "No automatic fix exists for this check.")
        }
        var fixed: [String] = []
        for result in targets {
            guard let fix = await registry.fix(for: result.id) else { continue }
            do {
                try await fix.apply(context)
                fixed.append(result.id)
            } catch {
                throw RuntimeWireError(
                    domain: "diagnostics", code: "diagnostics.fixFailed",
                    message: "The fix for \(result.id) did not complete.")
            }
        }
        let rerun = await registry.run(deep: false, context: healthContext())
        publishHealthChanges(rerun)
        return Self.wireReport(
            rerun, verdictContext: healthVerdictContext(),
            fixed: fixed.isEmpty ? [first.id] : fixed)
    }

    /// Emits a coalesced `healthChanged` event per changed result (§13).
    private func publishHealthChanges(_ results: [HealthResult]) {
        var changed = false
        for result in results where healthPublished[result.id] != result.state {
            healthPublished[result.id] = result.state
            changed = true
            eventHub.publishHealthEvent(
                HealthEvent(result: Self.wireResult(result)))
        }
        if changed {
            healthLastKnown = results.reduce(into: healthLastKnown) { map, result in
                map[result.id] = LastKnown(
                    state: result.state, detail: result.detail,
                    measuredAt: result.measuredAt)
            }
        }
    }

    /// The verdict inputs for `HealthVerdict.evaluate` (§7.2).
    private func healthVerdictContext() -> HealthVerdictContext {
        let state: HealthRuntimeState =
            switch runtimeStateSnapshot {
            case .stopped: .stopped
            case .ready: .ready
            case .failed: .failed
            case .booting, .stopping: .other
            }
        return HealthVerdictContext(
            runtimeState: state,
            provisioningComplete: provisioningState == .complete
        )
    }

    /// Renders an error parameter for the wire.
    private static func wireParameter(_ parameter: ErrorParameter) -> String {
        switch parameter {
        case .text(let value), .fileName(let value): value
        case .bytes(let value): "\(value)"
        case .count(let value): "\(value)"
        case .duration(let value): "\(value)"
        }
    }

    /// The safe repairs `doctor --fix` can run inside the daemon (§7.5).
    /// Host-side repairs (wrapper re-registration via LaunchServices is the
    /// daemon's own sweep; apkrund.restart uses launchctl) live here; the
    /// registration fix itself is client-side (`open -a APKRun`).
    private func healthFixes() -> [HealthCheckID: any HealthFix] {
        [
            "wrappers.registration": ClosureHealthFix(
                id: "wrappers.registration"
            ) { [weak self] _ in
                guard let self else { return }
                await self.runWrapperSweep()
            },
            "apkrund.version": ClosureHealthFix(
                id: "apkrund.version"
            ) { _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = [
                    "kickstart", "-k",
                    "gui/\(getuid())/io.apkrun.apkrund",
                ]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw RuntimeWireError(
                        domain: "diagnostics", code: "diagnostics.fixFailed",
                        message: "launchctl kickstart failed.")
                }
            },
        ]
    }

    /// Converts a check result to its wire row.
    static func wireResult(_ result: HealthResult) -> WireHealthResult {
        WireHealthResult(
            id: result.id,
            group: result.group.rawValue,
            state: result.state.rawValue,
            title: WireLocalizedText(
                key: result.title.key,
                parameters: result.title.parameters.mapValues(Self.wireParameter),
                fallback: result.title.fallback),
            detail: result.detail,
            error: result.error?.code,
            fixAvailable: result.fixAvailable,
            lastKnown: result.lastKnown.map {
                WireHealthLastKnown(
                    state: $0.state.rawValue, detail: $0.detail,
                    measuredAt: $0.measuredAt)
            },
            measuredAt: result.measuredAt
        )
    }

    /// Builds the wire report for a finished run.
    static func wireReport(
        _ results: [HealthResult],
        verdictContext: HealthVerdictContext,
        fixed: [String]
    ) -> WireHealthReport {
        let verdict = HealthVerdict.evaluate(results: results, context: verdictContext)
        return WireHealthReport(
            results: results.map(wireResult),
            verdict: verdict.rawValue,
            statusLine: Self.statusLine(for: verdict),
            fixed: fixed
        )
    }

    /// The one-line status each verdict prints (diagnostics.md §7.2).
    private static func statusLine(for verdict: HealthVerdict) -> String {
        switch verdict {
        case .healthy: "APKRun is healthy."
        case .stopped: "Android is stopped."
        case .degraded: "APKRun is degraded."
        case .notSetUp: "APKRun isn't set up yet."
        case .serviceUnavailable: "APKRun's background service isn't running."
        case .hostUnsupported: "APKRun can't run on this Mac."
        case .graphicsFailure: "Android graphics failed."
        case .bootFailure: "Android didn't start."
        case .agentUnavailable: "Android's agent isn't answering."
        case .unknown: "APKRun's status is unknown."
        }
    }
}
