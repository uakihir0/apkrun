import DiagnosticsCore
import Foundation
import Testing

@Test func doctorSymbolsMatchTheSpecTable() {
    #expect(DoctorFormatter.symbol(for: "pass") == "✓")
    #expect(DoctorFormatter.symbol(for: "info") == "ℹ")
    #expect(DoctorFormatter.symbol(for: "warning") == "⚠")
    #expect(DoctorFormatter.symbol(for: "failure") == "✕")
    #expect(DoctorFormatter.symbol(for: "skipped") == "–")
}

@Test func doctorExitCodeFollowsTheVerdict() {
    let passing = [DoctorRow(id: "a.b", group: "host", state: "pass", title: "ok")]
    let warning = [DoctorRow(id: "a.b", group: "host", state: "warning", title: "warn")]
    let failing = [DoctorRow(id: "a.b", group: "host", state: "failure", title: "bad")]
    #expect(DoctorFormatter.exitCode(verdict: "healthy", rows: passing) == 0)
    #expect(DoctorFormatter.exitCode(verdict: "stopped", rows: passing) == 0)
    #expect(DoctorFormatter.exitCode(verdict: "healthy", rows: warning) == 0)
    #expect(DoctorFormatter.exitCode(verdict: "healthy", rows: failing) == 1)
    #expect(DoctorFormatter.exitCode(verdict: "degraded", rows: warning) == 3)
    #expect(DoctorFormatter.exitCode(verdict: "degraded", rows: failing) == 1)
    #expect(DoctorFormatter.exitCode(verdict: "serviceUnavailable", rows: failing) == 1)
}

@Test func doctorFormatRendersRowsAndIndentedRemediation() {
    let text = DoctorFormatter.format(
        rows: [
            DoctorRow(
                id: "host.appleSilicon", group: "host", state: "pass",
                title: "Apple silicon"),
            DoctorRow(
                id: "apkrund.reachable", group: "backgroundService",
                state: "failure", title: "Background service",
                detail: "No answer on the control socket.",
                remediation: "Run `open -a APKRun`, then run `apkrun doctor` again."),
            DoctorRow(
                id: "agent.guest", group: "guest", state: "skipped",
                title: "Guest Agent", skipReason: "Background service not running"),
        ],
        statusLine: "Background service is not running."
    )
    #expect(text.hasPrefix("Background service is not running.\n"))
    #expect(text.contains("✓ host.appleSilicon — Apple silicon\n"))
    #expect(text.contains("✕ apkrund.reachable — Background service\n"))
    #expect(text.contains("    No answer on the control socket.\n"))
    #expect(text.contains("    Run `open -a APKRun`, then run `apkrun doctor` again.\n"))
    #expect(text.contains("– agent.guest — Guest Agent\n"))
    #expect(text.contains("    Background service not running\n"))
    #expect(!text.contains("\u{001B}"))
}

@Test func doctorFormatRendersDeepMetricsBlock() {
    let text = DoctorFormatter.format(
        rows: [DoctorRow(id: "a.b", group: "host", state: "pass", title: "ok")],
        statusLine: "Healthy.",
        metrics: [(name: "boot", value: "median 1200ms p95 2400ms")]
    )
    #expect(text.contains("\nMetrics:\n"))
    #expect(text.contains("    boot: median 1200ms p95 2400ms\n"))
}

@Test func doctorFormatColorsOnlyWhenAsked() {
    let rows = [DoctorRow(id: "a.b", group: "host", state: "failure", title: "bad")]
    #expect(DoctorFormatter.format(rows: rows, statusLine: "x", useColor: true).contains("\u{001B}[31m"))
    #expect(!DoctorFormatter.format(rows: rows, statusLine: "x").contains("\u{001B}"))
}

@Test func doctorJSONCarriesSchemaVersionAndResults() throws {
    let text = DoctorFormatter.json(
        rows: [
            DoctorRow(
                id: "apkrund.reachable", group: "backgroundService",
                state: "failure", title: "Background service",
                detail: "down", error: "diagnostics.daemonUnavailable",
                fixAvailable: true)
        ],
        verdict: "serviceUnavailable",
        statusLine: "Background service is not running.",
        fixed: ["apkrund.version"]
    )
    let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    #expect(object?["schemaVersion"] as? Int == 1)
    #expect(object?["verdict"] as? String == "serviceUnavailable")
    #expect(object?["statusLine"] as? String == "Background service is not running.")
    #expect(object?["fixed"] as? [String] == ["apkrund.version"])
    let results = object?["results"] as? [[String: Any]]
    #expect(results?.count == 1)
    #expect(results?.first?["id"] as? String == "apkrund.reachable")
    #expect(results?.first?["fixAvailable"] as? Bool == true)
}
