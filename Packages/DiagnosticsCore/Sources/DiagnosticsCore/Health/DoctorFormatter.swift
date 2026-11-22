import Foundation

/// One rendered row of `apkrun doctor` output (diagnostics.md §7.3). The CLI
/// maps `WireHealthResult` onto this so the formatter needs no wire types.
public struct DoctorRow: Sendable, Equatable {
    /// The check identifier.
    public var id: String
    /// The report section.
    public var group: String
    /// `pass`, `info`, `warning`, `failure`, or `skipped`.
    public var state: String
    /// The check's display title.
    public var title: String
    /// Additional detail, if any.
    public var detail: String?
    /// The catalog error code, if any.
    public var error: String?
    /// The catalog remediation text, if any.
    public var remediation: String?
    /// Whether a safe repair exists.
    public var fixAvailable: Bool
    /// Why the row was skipped, in `skipped` rows.
    public var skipReason: String?

    /// Creates a row.
    public init(
        id: String,
        group: String,
        state: String,
        title: String,
        detail: String? = nil,
        error: String? = nil,
        remediation: String? = nil,
        fixAvailable: Bool = false,
        skipReason: String? = nil
    ) {
        self.id = id
        self.group = group
        self.state = state
        self.title = title
        self.detail = detail
        self.error = error
        self.remediation = remediation
        self.fixAvailable = fixAvailable
        self.skipReason = skipReason
    }
}

/// Renders the doctor report: the status line, then one row per check in
/// §7.4 order, plus the Metrics block for `--deep` (diagnostics.md §7.3).
public enum DoctorFormatter {

    /// The status symbol for a check state.
    public static func symbol(for state: String) -> String {
        switch state {
        case "pass": "✓"
        case "info": "ℹ"
        case "warning": "⚠"
        case "failure": "✕"
        case "skipped": "–"
        default: "?"
        }
    }

    /// The process exit code (§7.3): healthy or stopped is 0, warnings only
    /// is 3, anything else is 1.
    public static func exitCode(verdict: String, rows: [DoctorRow]) -> Int32 {
        switch verdict {
        case "healthy", "stopped":
            return rows.contains { $0.state == "failure" } ? 1 : 0
        case "degraded":
            return rows.contains { $0.state == "failure" } ? 1 : 3
        default:
            return 1
        }
    }

    /// The human-readable report.
    ///
    /// - Parameters:
    ///   - rows: The results in §7.4 order.
    ///   - statusLine: The daemon's verdict line.
    ///   - metrics: `name: value` lines for the `--deep` Metrics block.
    ///   - useColor: Whether to wrap symbols in ANSI colors (TTY only,
    ///     never under `NO_COLOR`).
    public static func format(
        rows: [DoctorRow],
        statusLine: String,
        metrics: [(name: String, value: String)] = [],
        useColor: Bool = false
    ) -> String {
        var out = [statusLine]
        for row in rows {
            var line = "\(colored(symbol(for: row.state), state: row.state, useColor: useColor)) "
            line += "\(row.id) — \(row.title)"
            out.append(line)
            if let detail = row.detail, !detail.isEmpty {
                out.append("    \(detail)")
            }
            if let skip = row.skipReason, !skip.isEmpty {
                out.append("    \(skip)")
            }
            if let remediation = row.remediation, !remediation.isEmpty {
                out.append("    \(remediation)")
            }
        }
        if !metrics.isEmpty {
            out.append("")
            out.append("Metrics:")
            for metric in metrics {
                out.append("    \(metric.name): \(metric.value)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// The `--json` report (`{"schemaVersion": 1, ...}`).
    public static func json(
        rows: [DoctorRow],
        verdict: String,
        statusLine: String,
        fixed: [String] = []
    ) -> String {
        var objects: [String: Any] = [
            "schemaVersion": 1,
            "verdict": verdict,
            "statusLine": statusLine,
        ]
        if !fixed.isEmpty {
            objects["fixed"] = fixed
        }
        objects["results"] = rows.map { row in
            [
                "id": row.id,
                "group": row.group,
                "state": row.state,
                "title": row.title,
                "detail": row.detail as Any,
                "error": row.error as Any,
                "fixAvailable": row.fixAvailable,
            ] as [String: Any]
        }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: objects, options: [.sortedKeys, .prettyPrinted]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}\n"
        }
        return text + "\n"
    }

    private static func colored(_ symbol: String, state: String, useColor: Bool) -> String {
        guard useColor else { return symbol }
        switch state {
        case "pass": return "\u{001B}[32m\(symbol)\u{001B}[0m"
        case "warning": return "\u{001B}[33m\(symbol)\u{001B}[0m"
        case "failure": return "\u{001B}[31m\(symbol)\u{001B}[0m"
        default: return symbol
        }
    }
}
