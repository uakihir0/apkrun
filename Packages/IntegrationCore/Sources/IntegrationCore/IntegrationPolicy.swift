import Foundation
import RuntimeAPI

/// The policy evaluation of desktop-integration.md §2.3.
///
/// Every integration request passes the Guest Agent, then this policy, then the
/// host adapter. The policy reads the per-package `integrations.*` settings and
/// the global `integrations.enabled.*` switches on every evaluation; nothing is
/// cached past a settings change.

/// The decision of `IntegrationPolicy.evaluate` (desktop-integration.md §2.3).
public enum IntegrationDecision: Sendable, Equatable {
    /// The integration may proceed.
    case allow
    /// Ask the user; links only (desktop-integration.md §7).
    case ask
    /// The integration is refused.
    case deny(IntegrationDenial)
}

/// What an integration rule needs to know (desktop-integration.md §2.3).
public struct IntegrationContext: Sendable, Equatable {
    /// A session of the package exists.
    public var hasSession: Bool
    /// A window of the package is the key window.
    public var windowIsKey: Bool
    /// The capability the operation needs; nil skips the image check.
    public var requiredCapability: String?

    /// Creates a context.
    public init(hasSession: Bool, windowIsKey: Bool, requiredCapability: String? = nil) {
        self.hasSession = hasSession
        self.windowIsKey = windowIsKey
        self.requiredCapability = requiredCapability
    }
}

/// The settings an evaluation reads (desktop-integration.md §2.1–§2.2).
///
/// `packageValue` returns the stored `integrations.<key>` value for the
/// package (`true`, `false`, or an enum word like `ask`); `nil` means the
/// default of §2.1 and covers unmanaged packages. `globalEnabled` answers the
/// global switch, and `supported` the capabilities of the running image.
public struct IntegrationSettingsSource: Sendable {
    /// The package's stored value for an integration key, or nil for its default.
    public var packageValue: @Sendable (IntegrationKind, RuntimePackageID) -> String?
    /// The global `integrations.enabled.<name>` switch.
    public var globalEnabled: @Sendable (IntegrationKind) -> Bool
    /// Whether the running image reports a capability (guest-protocol.md §5.3).
    public var supported: @Sendable (String) -> Bool

    /// Creates a settings source.
    public init(
        packageValue: @escaping @Sendable (IntegrationKind, RuntimePackageID) -> String?,
        globalEnabled: @escaping @Sendable (IntegrationKind) -> Bool,
        supported: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.packageValue = packageValue
        self.globalEnabled = globalEnabled
        self.supported = supported
    }
}

/// The per-kind default value of desktop-integration.md §2.1. An unmanaged
/// package has no settings file and uses these, except `notifications`, which
/// is off for it (configuration.md §3.2).
public enum IntegrationDefaults {
    /// The §2.1 default of a managed package's `integrations.<kind>` value.
    public static func value(for kind: IntegrationKind) -> String {
        switch kind {
        case .clipboard, .notifications, .files:
            return "true"
        case .links:
            return "ask"
        case .sharedFolders:
            return "off"
        case .microphone:
            return "false"
        }
    }
}

/// Counted denials per kind and reason (`integration.denied{kind, reason}`,
/// desktop-integration.md §2.3).
public struct IntegrationDenialCounts: Sendable, Equatable {
    /// The count per `(kind, reason)` pair.
    public internal(set) var counts: [IntegrationKind: [IntegrationDenial: Int]] = [:]

    /// The denial count of one kind and reason.
    public func count(_ kind: IntegrationKind, _ reason: IntegrationDenial) -> Int {
        counts[kind]?[reason] ?? 0
    }
}

/// Evaluates `integrations.*` switches (desktop-integration.md §2.3).
public actor IntegrationPolicy {
    private let source: IntegrationSettingsSource
    private var denials = IntegrationDenialCounts()

    /// Creates a policy over the given settings source.
    public init(source: IntegrationSettingsSource) {
        self.source = source
    }

    /// Evaluates one integration request (desktop-integration.md §2.3).
    public func evaluate(
        _ kind: IntegrationKind,
        package: RuntimePackageID,
        context: IntegrationContext
    ) -> IntegrationDecision {
        let decision = decide(kind, package: package, context: context)
        if case .deny(let reason) = decision {
            denials.counts[kind, default: [:]][reason, default: 0] += 1
        }
        return decision
    }

    /// Denial counts since the policy was created (`integration.denied{kind, reason}`).
    public var denialCounts: IntegrationDenialCounts {
        denials
    }

    private func decide(
        _ kind: IntegrationKind,
        package: RuntimePackageID,
        context: IntegrationContext
    ) -> IntegrationDecision {
        guard source.globalEnabled(kind) else {
            return .deny(.globallyOff)
        }
        let value = source.packageValue(kind, package) ?? IntegrationDefaults.value(for: kind)
        switch kind {
        case .clipboard, .notifications, .files, .microphone:
            guard value == "true" else {
                return .deny(.packageOff)
            }
        case .sharedFolders:
            guard value != "off" else {
                return .deny(.packageOff)
            }
        case .links:
            if value == "ask" {
                return .ask
            }
        // `mac` and `android` are both enabled answers for `evaluate`;
        // the caller interprets them.
        }
        if let capability = context.requiredCapability, !source.supported(capability) {
            return .deny(.notSupported)
        }
        // Notifications are asynchronous events, not window actions: §5.3
        // explicitly routes them to a background wrapper start or to APKRun's
        // own banner precisely when no session or key window exists.
        if kind != .notifications {
            guard context.hasSession else {
                return .deny(.noSession)
            }
            guard context.windowIsKey else {
                return .deny(.notFocused)
            }
        }
        return .allow
    }
}
