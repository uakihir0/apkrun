import Foundation
import RuntimeAPI
import RuntimeClient

/// Backs the Troubleshooting pane's health report (host-ui.md §9.8,
/// diagnostics.md §7.3): runs `healthReport`, and `applyHealthFixes` for the
/// Fix button.
@Observable
@MainActor
final class TroubleshootingModel {
    /// The latest report rows, in §7.4 order.
    private(set) var rows: [WireHealthResult] = []
    /// The daemon's one-line status.
    private(set) var statusLine = ""
    /// Whether a check or fix is in flight.
    private(set) var isRunning = false
    /// The last connection or decode failure, if any.
    private(set) var errorMessage: String?
    /// Check IDs fixed by the last `--fix` pass.
    private(set) var fixed: [String] = []

    private var client: RuntimeControlClient?

    /// Runs the quick checks (`Run Again`).
    func check(deep: Bool = false) async {
        await run {
            try await $0.healthReport(deep: deep)
        }
    }

    /// Applies every fixable failure (`Fix`).
    func fix() async {
        await run {
            try await $0.applyHealthFixes(checks: [])
        }
    }

    private func run(
        _ call: @escaping (RuntimeControlClient) async throws -> WireHealthReport
    ) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            if client == nil {
                client = try RuntimeControlClient(clientKind: .app)
            }
            guard let client else { return }
            let report = try await call(client)
            rows = report.results
            statusLine = report.statusLine
            fixed = report.fixed
            errorMessage = nil
        } catch {
            errorMessage = "APKRun's background service isn't running."
        }
    }

    /// Whether the attention banner shows in the menu bar and headers.
    var needsAttention: Bool {
        rows.contains { $0.state == "failure" }
    }
}
