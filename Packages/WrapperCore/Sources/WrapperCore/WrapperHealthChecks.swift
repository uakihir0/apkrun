import CoreServices
import DiagnosticsCore
import Foundation

/// Private LaunchServices lookup for bundle IDs (wrapper.md §14:
/// `wrappers.registration` reports wrappers LaunchServices forgot).
@_silgen_name("LSCopyApplicationURLsForBundleIdentifier")
private func _LSCopyApplicationURLsForBundleIdentifier(
    _ bundleID: CFString,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> Unmanaged<CFArray>?

/// The `wrappers.*` health checks owned by WrapperCore (wrapper.md §14).
public enum WrapperHealthChecks {
    /// A `wrappers.template` check for the installed launcher template.
    public static func template(executableURL: URL) -> any HealthCheck {
        TemplateCheck(executableURL: executableURL)
    }

    /// A `wrappers.registry` check bound to a registry.
    public static func registry(_ registry: WrapperRegistry) -> any HealthCheck {
        RegistryCheck(registry: registry)
    }

    /// A `wrappers.registration` check that warns when a registered
    /// wrapper's bundle ID is unknown to LaunchServices (wrapper.md §14).
    /// `knownToLaunchServices` is injectable for tests; never run
    /// `mdimport` or the `lsregister` tool here.
    public static func registration(
        _ registry: WrapperRegistry,
        knownToLaunchServices: (@Sendable (String) -> Bool)? = nil
    ) -> any HealthCheck {
        RegistrationCheck(
            registry: registry,
            knownToLaunchServices: knownToLaunchServices ?? { bundleID in
                _LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)
                    .map { CFArrayGetCount($0.takeRetainedValue()) > 0 } ?? false
            })
    }
}

private struct RegistrationCheck: HealthCheck {
    let registry: WrapperRegistry
    let knownToLaunchServices: @Sendable (String) -> Bool

    var id: HealthCheckID { "wrappers.registration" }
    var group: HealthGroup { .macApps }
    var requirement: HealthRequirement { .host }
    var cost: HealthCost { .quick }
    var title: LocalizedText { LocalizedText(key: id, fallback: "LaunchServices registration") }

    func run(_ context: HealthContext) async -> HealthResult {
        let outcome = await registry.load()
        guard case .ready = outcome else {
            return HealthResult(
                id: id,
                group: group,
                state: .warning,
                title: title,
                detail: "The wrapper registry is unreadable.",
                error: ErrorInfo(
                    code: "wrapper.registryUnavailable",
                    message: LocalizedText(
                        key: "wrapper.registryUnavailable",
                        fallback: "The wrapper registry is unreadable."),
                    remediation: LocalizedText(
                        key: "wrapper.registryUnavailable.remediation",
                        fallback: "Re-register Mac apps from the home screen.")
                ),
                fixAvailable: false,
                lastKnown: nil,
                measuredAt: Date()
            )
        }
        let missing = await registry.entries()
            .filter { $0.state == .active }
            .filter { !knownToLaunchServices($0.bundleId) }
        let state = missing.isEmpty ? HealthState.pass : .warning
        let detail =
            missing.isEmpty
            ? "LaunchServices knows every registered wrapper."
            : "LaunchServices does not know \(missing.count) registered wrapper(s): "
                + missing.map(\.fileName).sorted().joined(separator: ", ")
        let error: ErrorInfo? =
            missing.isEmpty
            ? nil
            : ErrorInfo(
                code: "wrapper.launchServicesMissing",
                message: LocalizedText(
                    key: "wrapper.launchServicesMissing", fallback: detail),
                remediation: LocalizedText(
                    key: "wrapper.launchServicesMissing.remediation",
                    fallback: "Open each Mac app once from its folder."),
                action: .retry
            )
        return HealthResult(
            id: id,
            group: group,
            state: state,
            title: title,
            detail: detail,
            error: error,
            fixAvailable: false,
            lastKnown: nil,
            measuredAt: Date()
        )
    }
}

private struct TemplateCheck: HealthCheck {
    let executableURL: URL

    var id: HealthCheckID { "wrappers.template" }
    var group: HealthGroup { .macApps }
    var requirement: HealthRequirement { .host }
    var cost: HealthCost { .quick }
    var title: LocalizedText { LocalizedText(key: id, fallback: "Launcher template") }

    func run(_ context: HealthContext) async -> HealthResult {
        let failure: String? =
            if !FileManager.default.fileExists(atPath: executableURL.path) {
                "the generic launcher is missing"
            } else if !WrapperCodeSign.isARM64(executableURL) {
                "the generic launcher is not arm64"
            } else if WrapperCodeSign.cdhash(of: executableURL) == nil {
                "the generic launcher signature is invalid"
            } else {
                nil
            }
        return HealthResult(
            id: id,
            group: group,
            state: failure == nil ? .pass : .warning,
            title: title,
            detail: failure ?? "The launcher template is present and valid.",
            error: failure.map {
                ErrorInfo(
                    code: "wrapper.launcherTemplateInvalid",
                    message: LocalizedText(
                        key: "wrapper.launcherTemplateInvalid", fallback: $0),
                    remediation: LocalizedText(
                        key: "wrapper.launcherTemplateInvalid.remediation",
                        fallback: "Reinstall APKRun."),
                    action: .reinstallApp
                )
            },
            fixAvailable: false,
            lastKnown: nil,
            measuredAt: Date()
        )
    }
}

private struct RegistryCheck: HealthCheck {
    let registry: WrapperRegistry

    var id: HealthCheckID { "wrappers.registry" }
    var group: HealthGroup { .macApps }
    var requirement: HealthRequirement { .host }
    var cost: HealthCost { .quick }
    var title: LocalizedText { LocalizedText(key: id, fallback: "Wrapper registry") }

    func run(_ context: HealthContext) async -> HealthResult {
        let outcome = await registry.load()
        var state = HealthState.pass
        var detail = "The wrapper registry is healthy."
        var error: ErrorInfo?
        switch outcome {
        case .corrupt:
            state = .warning
            detail = "registry.json is unreadable and was kept aside."
            error = unavailable(remediation: "Re-register Mac apps from the home screen.")
        case .newerVersion:
            state = .warning
            detail = "registry.json was written by a newer APKRun."
            error = unavailable(remediation: "Update APKRun.")
        case .ready:
            if await registry.hasUnresolvedPendingEntries {
                state = .warning
                detail = "Pending wrapper entries remain after recovery."
                error = ErrorInfo(
                    code: "wrapper.registryPending",
                    message: LocalizedText(
                        key: "wrapper.registryPending", fallback: detail),
                    remediation: LocalizedText(
                        key: "wrapper.registryPending.remediation",
                        fallback: "Create a diagnostics report.")
                )
            }
        }
        return HealthResult(
            id: id,
            group: group,
            state: state,
            title: title,
            detail: detail,
            error: error,
            fixAvailable: false,
            lastKnown: nil,
            measuredAt: Date()
        )
    }

    private func unavailable(remediation: String) -> ErrorInfo {
        ErrorInfo(
            code: "wrapper.registryUnavailable",
            message: LocalizedText(
                key: "wrapper.registryUnavailable",
                fallback: "The wrapper registry is unreadable."),
            remediation: LocalizedText(
                key: "wrapper.registryUnavailable.remediation", fallback: remediation)
        )
    }
}
