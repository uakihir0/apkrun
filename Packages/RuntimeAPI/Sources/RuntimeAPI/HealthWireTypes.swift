import Foundation

/// `healthReport` request (runtime-api.md §13): a quick report takes at most
/// 15 s, a deep one 3 minutes. `checks` nil means every registered check.
public struct HealthRequest: Codable, Equatable, Sendable {
    /// Run deep checks too.
    public var deep: Bool
    /// Restrict the report to these check IDs; nil runs all.
    public var checks: [String]?

    /// Creates a health report request.
    public init(deep: Bool = false, checks: [String]? = nil) {
        self.deep = deep
        self.checks = checks
    }
}

/// `applyHealthFixes` request (runtime-api.md §13): runs the safe repairs of
/// the named failed checks. An empty list means every failed check that
/// offers a fix.
public struct HealthFixRequest: Codable, Equatable, Sendable {
    /// The check IDs to fix; empty means all fixable failures.
    public var checks: [String]

    /// Creates a fix request.
    public init(checks: [String] = []) {
        self.checks = checks
    }
}

/// The previous result of a skipped check (runtime-api.md §13).
public struct WireHealthLastKnown: Codable, Equatable, Sendable {
    /// The earlier outcome.
    public var state: String
    /// Earlier detail, if any.
    public var detail: String?
    /// When it was measured.
    public var measuredAt: Date

    /// Creates a last-known row.
    public init(state: String, detail: String? = nil, measuredAt: Date) {
        self.state = state
        self.detail = detail
        self.measuredAt = measuredAt
    }
}

/// One check result on the wire (runtime-api.md §13). `state` is one of
/// `pass`, `info`, `warning`, `failure`, `skipped`.
public struct WireHealthResult: Codable, Equatable, Sendable {
    /// The stable check identifier.
    public var id: String
    /// The report section.
    public var group: String
    /// The outcome.
    public var state: String
    /// The localized check title.
    public var title: WireLocalizedText
    /// Additional human-readable detail.
    public var detail: String?
    /// The catalog error code, when the check reported one.
    public var error: String?
    /// Whether a safe repair exists.
    public var fixAvailable: Bool
    /// The prior result when this check was skipped.
    public var lastKnown: WireHealthLastKnown?
    /// When this result was measured.
    public var measuredAt: Date

    /// Creates a wire result row.
    public init(
        id: String,
        group: String,
        state: String,
        title: WireLocalizedText,
        detail: String? = nil,
        error: String? = nil,
        fixAvailable: Bool = false,
        lastKnown: WireHealthLastKnown? = nil,
        measuredAt: Date
    ) {
        self.id = id
        self.group = group
        self.state = state
        self.title = title
        self.detail = detail
        self.error = error
        self.fixAvailable = fixAvailable
        self.lastKnown = lastKnown
        self.measuredAt = measuredAt
    }
}

/// The `healthReport`/`applyHealthFixes` reply (runtime-api.md §13): the
/// ordered results plus the §7.2 verdict.
public struct WireHealthReport: Codable, Equatable, Sendable {
    /// The per-check rows in §7.4 order.
    public var results: [WireHealthResult]
    /// The overall verdict (`healthy`, `degraded`, …).
    public var verdict: String
    /// The one-line status text.
    public var statusLine: String
    /// Check IDs whose fix ran (`applyHealthFixes` only).
    public var fixed: [String]

    /// Creates a report reply.
    public init(
        results: [WireHealthResult],
        verdict: String,
        statusLine: String,
        fixed: [String] = []
    ) {
        self.results = results
        self.verdict = verdict
        self.statusLine = statusLine
        self.fixed = fixed
    }

    /// An error reply carrying a `RuntimeWireError` payload.
    public init(error: RuntimeWireError) {
        results = []
        verdict = "unknown"
        statusLine = error.message
        fixed = []
    }
}

/// A `healthChanged` event (runtime-api.md §13, topic `health`): one live
/// check's new result, coalesced per check ID.
public struct HealthEvent: Codable, Equatable, Sendable {
    /// The check's new result.
    public var result: WireHealthResult

    /// Creates an event.
    public init(result: WireHealthResult) {
        self.result = result
    }
}
