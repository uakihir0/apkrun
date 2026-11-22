import Foundation

/// A health check whose measurement is a closure. Check catalogues in other
/// modules build these instead of declaring a type per check (diagnostics.md
/// §7.4): the ID, group, requirement, and cost are data; `measure` returns the
/// state, an optional detail, and an optional error.
public struct ClosureHealthCheck: HealthCheck {
    /// The stable identifier of the check.
    public let id: HealthCheckID
    /// The report section that owns this check.
    public let group: HealthGroup
    /// The runtime state required before this check runs.
    public let requirement: HealthRequirement
    /// Whether the check is quick or deep-only.
    public let cost: HealthCost
    /// The localized title shown in reports.
    public let title: LocalizedText
    /// An optional safe repair.
    public let fix: (any HealthFix)?

    private let measure: @Sendable (HealthContext) async -> HealthOutcome

    /// The measured outcome of a closure check.
    public struct HealthOutcome: Sendable {
        /// The outcome of the check.
        public let state: HealthState
        /// Additional human-readable detail.
        public let detail: String?
        /// Structured error details.
        public let error: ErrorInfo?

        /// Creates an outcome.
        public init(state: HealthState, detail: String? = nil, error: ErrorInfo? = nil) {
            self.state = state
            self.detail = detail
            self.error = error
        }
    }

    /// Creates a closure-backed check.
    public init(
        id: HealthCheckID,
        group: HealthGroup,
        requirement: HealthRequirement,
        cost: HealthCost = .quick,
        title: LocalizedText? = nil,
        fix: (any HealthFix)? = nil,
        measure: @escaping @Sendable (HealthContext) async -> HealthOutcome
    ) {
        self.id = id
        self.group = group
        self.requirement = requirement
        self.cost = cost
        self.title = title ?? LocalizedText(key: id, fallback: id)
        self.fix = fix
        self.measure = measure
    }

    /// Runs the closure and wraps its outcome in a result row.
    public func run(_ context: HealthContext) async -> HealthResult {
        let outcome = await measure(context)
        return HealthResult(
            id: id,
            group: group,
            state: outcome.state,
            title: title,
            detail: outcome.detail,
            error: outcome.error,
            fixAvailable: fix != nil,
            measuredAt: context.clock.now
        )
    }
}

/// A repair described by an ID and a closure (diagnostics.md §7.5).
public struct ClosureHealthFix: HealthFix {
    /// The check this fix belongs to.
    public let id: HealthCheckID

    private let apply: @Sendable (HealthContext) async throws -> Void

    /// Creates a closure-backed fix.
    public init(id: HealthCheckID, apply: @escaping @Sendable (HealthContext) async throws -> Void) {
        self.id = id
        self.apply = apply
    }

    /// Applies the fix.
    public func apply(_ context: HealthContext) async throws {
        try await apply(context)
    }
}
