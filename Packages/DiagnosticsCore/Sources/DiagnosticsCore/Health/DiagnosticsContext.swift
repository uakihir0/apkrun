import Foundation

/// Shared diagnostics dependencies supplied to module entry points.
public struct DiagnosticsContext: Sendable {
    /// The sink used for structured diagnostics events.
    public let logSink: any LogSink

    /// The registered host and runtime health checks.
    public let healthChecks: HealthCheckRegistry

    /// The process-wide lifecycle performance timeline.
    public let perfTimeline: PerfTimeline

    /// APKRun's host data paths.
    public let paths: APKRunPaths

    /// A clock that can be replaced in deterministic tests.
    public let clock: any DiagnosticsClock

    /// The host application build metadata.
    public let buildInfo: BuildInfo

    /// The host system probe used by health checks.
    public let hostProbe: any HostProbe

    /// Creates the dependencies used by the diagnostics service.
    public init(
        logSink: any LogSink,
        healthChecks: HealthCheckRegistry,
        perfTimeline: PerfTimeline,
        paths: APKRunPaths,
        clock: any DiagnosticsClock,
        buildInfo: BuildInfo = .current,
        hostProbe: any HostProbe = SystemHostProbe()
    ) {
        self.logSink = logSink
        self.healthChecks = healthChecks
        self.perfTimeline = perfTimeline
        self.paths = paths
        self.clock = clock
        self.buildInfo = buildInfo
        self.hostProbe = hostProbe
    }

    /// Creates the production diagnostics dependencies for a process.
    public static func live(paths: APKRunPaths) -> Self {
        Self(
            logSink: OSLogSink(subsystem: .diagnostics, category: "health"),
            healthChecks: HealthCheckRegistry(checks: HostChecks.all),
            perfTimeline: Perf.timeline,
            paths: paths,
            clock: SystemDiagnosticsClock(),
            buildInfo: .current,
            hostProbe: SystemHostProbe()
        )
    }

    /// Creates the health input from the context's shared dependencies.
    public func healthContext(
        daemonAvailable: Bool,
        runtimeRunning: Bool,
        lastKnown: [HealthCheckID: LastKnown] = [:]
    ) -> HealthContext {
        HealthContext(
            daemonAvailable: daemonAvailable,
            runtimeRunning: runtimeRunning,
            lastKnown: lastKnown,
            buildInfo: buildInfo,
            paths: paths,
            clock: clock,
            hostProbe: hostProbe
        )
    }
}
