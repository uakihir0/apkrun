import DiagnosticsCore
import Foundation

extension DiagnosticsContext {
    /// A deterministic context for module tests. The path override is explicit and isolated.
    public static func testing(
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "APKRun-DiagnosticsTests",
            isDirectory: true
        ),
        logSink: any LogSink = RecordingLogSink(),
        clock: any DiagnosticsClock = ManualDiagnosticsClock(),
        buildInfo: BuildInfo = .current,
        hostProbe: any HostProbe = FakeHostProbe(),
        healthTimeouts: HealthCheckTimeouts = .standard
    ) -> DiagnosticsContext {
        let paths = APKRunPaths(
            allowingHomeOverride: true,
            environment: ["APKRUN_HOME": root.path]
        )
        return DiagnosticsContext(
            logSink: logSink,
            healthChecks: HealthCheckRegistry(checks: HostChecks.all, timeouts: healthTimeouts),
            perfTimeline: PerfTimeline(),
            paths: paths,
            clock: clock,
            buildInfo: buildInfo,
            hostProbe: hostProbe
        )
    }
}
