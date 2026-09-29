import Foundation

/// Shared diagnostics dependencies supplied to module entry points.
public struct DiagnosticsContext: Sendable {
    public let logSink: any LogSink
    public let healthChecks: HealthCheckRegistry
    public let perfTimeline: PerfTimeline
    public let paths: APKRunPaths
    public let clock: any DiagnosticsClock
    public let buildInfo: BuildInfo
    public let hostProbe: any HostProbe

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
