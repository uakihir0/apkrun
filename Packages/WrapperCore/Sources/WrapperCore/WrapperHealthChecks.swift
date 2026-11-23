import DiagnosticsCore
import Foundation

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
