import Foundation

/// Stable identifier for a health check, such as `runtime.boot`.
public typealias HealthCheckID = String

/// The result state reported by a health check.
public enum HealthState: String, Codable, CaseIterable, Equatable, Sendable {
    case pass
    case info
    case warning
    case failure
    case skipped
}

/// The section that owns a health check in reports.
public enum HealthGroup: String, Codable, CaseIterable, Equatable, Sendable {
    case host
    case backgroundService
    case virtualization
    case android
    case graphics
    case guest
    case store
    case updates
    case applications
    case macApps
    case integrations
    case maintenance
}

/// The runtime resource a check requires before it can run.
public enum HealthRequirement: String, Codable, Equatable, Sendable {
    case host
    case daemon
    case runningRuntime
}

/// Whether a check is included in a normal or deep report.
public enum HealthCost: String, Codable, Equatable, Sendable {
    case quick
    case deep
}

/// A localized message key plus safe parameters and an English fallback.
public struct LocalizedText: Codable, Equatable, Sendable {
    /// The stable localization key.
    public let key: String

    /// Safe values substituted into the localized message.
    public let parameters: [String: ErrorParameter]

    /// The English fallback used when no translation exists.
    public let fallback: String

    /// Creates a localization value with safe substitution parameters.
    public init(
        key: String,
        parameters: [String: ErrorParameter] = [:],
        fallback: String
    ) {
        self.key = key
        self.parameters = parameters
        self.fallback = fallback
    }
}

/// Catalog-backed error content attached to a warning or failure result.
public struct ErrorInfo: Codable, Equatable, Sendable {
    /// The qualified catalog error code.
    public let code: String

    /// The user-facing error message.
    public let message: LocalizedText

    /// Optional guidance for resolving the error.
    public let remediation: LocalizedText?

    /// An optional action a user can take.
    public let action: RemediationAction?

    /// Creates catalog-backed error details for a health result.
    public init(
        code: String,
        message: LocalizedText,
        remediation: LocalizedText? = nil,
        action: RemediationAction? = nil
    ) {
        self.code = code
        self.message = message
        self.remediation = remediation
        self.action = action
    }
}

/// The most recent known result for a check that was skipped.
public struct LastKnown: Codable, Equatable, Sendable {
    /// The state from the previous execution.
    public let state: HealthState

    /// Optional detail from the previous execution.
    public let detail: String?

    /// When the previous result was measured.
    public let measuredAt: Date

    /// Creates a cached result for a skipped check.
    public init(state: HealthState, detail: String? = nil, measuredAt: Date) {
        self.state = state
        self.detail = detail
        self.measuredAt = measuredAt
    }
}

/// One health check result.
public struct HealthResult: Codable, Equatable, Sendable {
    /// The stable identifier of the check.
    public let id: HealthCheckID

    /// The report section that owns the result.
    public let group: HealthGroup

    /// The outcome of the check.
    public let state: HealthState

    /// The localized check title.
    public let title: LocalizedText

    /// Additional human-readable detail.
    public let detail: String?

    /// Structured error details, when the check reports an error.
    public let error: ErrorInfo?

    /// Whether the result offers a repair.
    public let fixAvailable: Bool

    /// The prior result when this check was skipped.
    public let lastKnown: LastKnown?

    /// When this result was measured.
    public let measuredAt: Date

    /// Creates one result row for a health report.
    public init(
        id: HealthCheckID,
        group: HealthGroup,
        state: HealthState,
        title: LocalizedText,
        detail: String? = nil,
        error: ErrorInfo? = nil,
        fixAvailable: Bool = false,
        lastKnown: LastKnown? = nil,
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

/// A complete health report assembled by the diagnostics service.
public struct HealthReport: Codable, Equatable, Sendable {
    /// When this report was assembled.
    public let generatedAt: Date

    /// The host application build that generated the report.
    public let build: BuildInfo

    /// The installed Android image version, if known.
    public let imageVersion: String?

    /// Whether Android was running when the report was assembled.
    public let runtimeRunning: Bool

    /// The overall status derived from check results and runtime state.
    public let verdict: HealthVerdict

    /// The ordered check results included in the report.
    public let results: [HealthResult]

    /// Creates a complete diagnostics report.
    public init(
        generatedAt: Date,
        build: BuildInfo,
        imageVersion: String? = nil,
        runtimeRunning: Bool,
        verdict: HealthVerdict,
        results: [HealthResult]
    ) {
        self.generatedAt = generatedAt
        self.build = build
        self.imageVersion = imageVersion
        self.runtimeRunning = runtimeRunning
        self.verdict = verdict
        self.results = results
    }
}

/// The runtime state used when selecting the report verdict.
public enum HealthRuntimeState: Equatable, Sendable {
    case stopped
    case ready
    case suspended
    case failed
    case other
}

/// Additional runtime facts that are not represented by individual check rows.
public struct HealthVerdictContext: Sendable {
    /// The daemon's current runtime state.
    public let runtimeState: HealthRuntimeState

    /// Whether initial image provisioning has completed.
    public let provisioningComplete: Bool

    /// Whether repeated boot failures activated the loop guard.
    public let bootLoopGuarded: Bool

    /// The most recent boot error code, if any.
    public let lastBootFailureCode: String?

    /// Creates the runtime facts used when choosing a report verdict.
    public init(
        runtimeState: HealthRuntimeState,
        provisioningComplete: Bool = true,
        bootLoopGuarded: Bool = false,
        lastBootFailureCode: String? = nil
    ) {
        self.runtimeState = runtimeState
        self.provisioningComplete = provisioningComplete
        self.bootLoopGuarded = bootLoopGuarded
        self.lastBootFailureCode = lastBootFailureCode
    }
}

/// The overall status selected for a health report.
public enum HealthVerdict: String, CaseIterable, Equatable, Sendable, Codable {
    case hostUnsupported
    case serviceUnavailable
    case notSetUp
    case graphicsFailure
    case bootFailure
    case agentUnavailable
    case degraded
    case stopped
    case healthy
    case unknown

    /// Decodes an unknown future verdict as `unknown`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }

    /// Encodes the stable verdict string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The first applicable condition in diagnostics.md §7.2.
    public static func evaluate(
        results: [HealthResult],
        context: HealthVerdictContext
    ) -> Self {
        func failed(_ id: String) -> Bool {
            results.contains { $0.id == id && $0.state == .failure }
        }

        if results.contains(where: {
            $0.state == .failure
                && ($0.id.hasPrefix("host.") || $0.id == "vm.virtualizationSupported")
        }) {
            return .hostUnsupported
        }
        if failed("apkrund.registration") || failed("apkrund.reachable") {
            return .serviceUnavailable
        }
        if !context.provisioningComplete
            || failed("runtime.provisioning")
            || failed("image.current")
        {
            return .notSetUp
        }
        if failed("graphics.renderer")
            || context.lastBootFailureCode.map(isGraphicsFailureCode) == true
            || results.contains(where: {
                $0.id == "runtime.boot" && $0.error.map { isGraphicsFailureCode($0.code) } == true
            })
        {
            return .graphicsFailure
        }
        if context.runtimeState == .failed
            || context.bootLoopGuarded
            || failed("runtime.state")
            || failed("runtime.boot")
        {
            return .bootFailure
        }
        if context.runtimeState == .ready
            && (failed("agent.guest") || failed("agent.store"))
        {
            return .agentUnavailable
        }
        if results.contains(where: { $0.state == .failure || $0.state == .warning }) {
            return .degraded
        }
        if context.runtimeState == .stopped {
            return .stopped
        }
        if context.runtimeState == .ready || context.runtimeState == .suspended {
            return .healthy
        }
        return .degraded
    }

    private static func isGraphicsFailureCode(_ code: String) -> Bool {
        code.hasPrefix("graphics.") || code == "runtime.graphics"
    }

    /// Returns the stable English status line used by CLI and GUI report headings.
    public func statusLine(
        results: [HealthResult],
        runtimeState: HealthRuntimeState
    ) -> String {
        switch self {
        case .hostUnsupported:
            return "APKRun can't run on this Mac"
        case .serviceUnavailable:
            return "Background service not running"
        case .notSetUp:
            return "Setup not finished"
        case .graphicsFailure:
            return "Graphics failed to start"
        case .bootFailure:
            if let bootResult = results.first(where: { $0.id == "runtime.boot" }),
                bootResult.state == .failure,
                let detail = bootResult.detail,
                !detail.isEmpty
            {
                return "Android failed to start · \(detail)"
            }
            return "Android failed to start"
        case .agentUnavailable:
            return results.first(where: {
                $0.id == "agent.guest" && $0.state == .failure
            }) != nil ? "Guest Agent unavailable" : "Store Agent unavailable"
        case .degraded:
            let warningCount = results.filter { $0.state == .warning }.count
            let warningLabel = warningCount == 1 ? "warning" : "warnings"
            let base =
                warningCount == 0
                ? "Needs attention"
                : "Needs attention (\(warningCount) \(warningLabel))"
            return runtimeState == .stopped ? "\(base) · Android is not running" : base
        case .stopped:
            return "Healthy · Android is not running"
        case .healthy:
            return "Healthy"
        case .unknown:
            return "Health status unavailable"
        }
    }
}
