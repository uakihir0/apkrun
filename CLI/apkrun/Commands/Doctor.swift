import ArgumentParser
import Darwin
import DiagnosticsCore
import Foundation
import RuntimeAPI
import RuntimeClient

/// `apkrun doctor [--deep] [--fix] [--json]`: the health report
/// (diagnostics.md §7).
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check APKRun's health and repair what is safe to repair."
    )

    @Flag(name: .long, help: "Run the deep checks too.")
    var deep = false

    @Flag(name: .long, help: "Apply the safe fixes of failed checks.")
    var fix = false

    @Flag(name: .long, help: "Print the report as JSON.")
    var json = false

    mutating func run() async throws {
        do {
            let (report, metrics) = try await daemonReport()
            try emit(report: report, metrics: metrics)
        } catch let code as ExitCode {
            throw code
        } catch {
            try await printHostOnly(cause: error)
        }
    }

    /// The daemon's report and the `--deep` metrics; throws when apkrund
    /// cannot be reached.
    private func daemonReport() async throws -> (
        report: WireHealthReport, metrics: [(name: String, value: String)]
    ) {
        let client = try RuntimeControlClient(clientKind: .cli)
        var report: WireHealthReport
        if fix {
            report = try await client.applyHealthFixes(checks: [])
            if !json {
                for row in report.results where report.fixed.contains(row.id) {
                    Output.write("Fixed: \(row.title.fallback)")
                }
            }
        } else {
            report = try await client.healthReport(deep: deep)
        }
        var metrics: [(name: String, value: String)] = []
        if deep, let stats = try? await client.perfStatistics() {
            metrics = Self.metricRows(stats)
        }
        return (report, metrics)
    }

    /// Writes a report and exits with the §7.3 code.
    private func emit(
        report: WireHealthReport, metrics: [(name: String, value: String)]
    ) throws {
        let rows = report.results.map(Self.row)
        if json {
            Output.write(
                DoctorFormatter.json(
                    rows: rows, verdict: report.verdict,
                    statusLine: report.statusLine, fixed: report.fixed))
        } else {
            Output.write(
                DoctorFormatter.format(
                    rows: rows, statusLine: report.statusLine,
                    metrics: metrics, useColor: Self.useColor))
        }
        throw ExitCode(DoctorFormatter.exitCode(verdict: report.verdict, rows: rows))
    }

    /// Runs the host-side checks locally when apkrund is down and prints the
    /// remaining checks as skipped (diagnostics.md §7.3).
    private func printHostOnly(cause: any Error) async throws {
        let rows = await hostOnlyRows()
        if json {
            Output.write(
                DoctorFormatter.json(
                    rows: rows, verdict: "serviceUnavailable",
                    statusLine: "APKRun's background service isn't running."))
        } else {
            Output.write(
                DoctorFormatter.format(
                    rows: rows,
                    statusLine: "APKRun's background service isn't running.",
                    useColor: Self.useColor))
        }
        throw ExitCode(1)
    }

    /// Host checks run locally plus every other check skipped with the §7.3
    /// "Background service not running" reason.
    private func hostOnlyRows() async -> [DoctorRow] {
        let paths = APKRunPaths(
            allowingHomeOverride: true, environment: ProcessInfo.processInfo.environment)
        let context = HealthContext(
            daemonAvailable: false,
            runtimeRunning: false,
            buildInfo: .current,
            paths: paths
        )
        var rows: [DoctorRow] = []
        let registry = HealthCheckRegistry(checks: HostChecks.all)
        let hostResults = await registry.run(context: context)
        rows.append(contentsOf: hostResults.map(Self.row))
        for id in [
            "vm.virtualizationSupported", "runtime.boot", "graphics.device",
            "graphics.renderer", "graphics.present", "graphics.memory",
            "graphics.safeMode", "graphics.guestDriver",
            "agent.guest", "agent.store", "agent.input", "agent.ime",
            "agent.developerMode",
            "apkrund.reachable", "apkrund.version", "apkrund.crashLoop",
            "apkrund.registration",
            "integration.time", "integrations.clipboard", "wrappers.registry",
            "wrappers.registration", "updates.waiting", "maintenance.selfUpdate",
        ] where !rows.contains(where: { $0.id == id }) {
            rows.append(
                DoctorRow(
                    id: id,
                    group: "backgroundService",
                    state: "skipped",
                    title: id,
                    skipReason: "Background service not running"
                ))
        }
        return rows
    }

    /// Whether the output is a TTY that honors colour.
    private static var useColor: Bool {
        isatty(STDOUT_FILENO) == 1
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }

    /// Maps a wire result onto a formatter row.
    private static func row(_ result: WireHealthResult) -> DoctorRow {
        DoctorRow(
            id: result.id,
            group: result.group,
            state: result.state,
            title: result.title.fallback,
            detail: result.detail,
            error: result.error,
            remediation: result.error.flatMap {
                ErrorCatalog.entry(for: $0)?.remediation?["en"]
            },
            fixAvailable: result.fixAvailable
        )
    }

    /// Maps a daemon health result (host-only mode) onto a formatter row.
    private static func row(_ result: HealthResult) -> DoctorRow {
        DoctorRow(
            id: result.id,
            group: result.group.rawValue,
            state: result.state.rawValue,
            title: result.title.fallback,
            detail: result.detail,
            error: result.error?.code,
            remediation: result.error?.remediation?.fallback,
            fixAvailable: result.fixAvailable
        )
    }

    /// The `--deep` Metrics block (diagnostics.md §7.3): marker medians and
    /// per-session graphics counters.
    private static func metricRows(_ stats: WirePerfStatistics) -> [(
        name: String, value: String
    )] {
        var rows: [(name: String, value: String)] = []
        for marker in stats.markers.prefix(8) {
            rows.append(
                (
                    name: marker.name,
                    value: "median \(marker.p50Us / 1000)ms p95 \(marker.p95Us / 1000)ms"
                ))
        }
        for session in stats.sessions {
            rows.append(
                (
                    name: "session \(session.packageID.rawValue) fps",
                    value: String(format: "%.1f", session.fps)
                ))
        }
        return rows
    }
}
