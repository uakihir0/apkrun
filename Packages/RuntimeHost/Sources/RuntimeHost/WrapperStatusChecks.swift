import DiagnosticsCore
import Foundation
import RuntimeAPI
import WrapperCore

/// The `wrappers.status` health check (wrapper.md §14): warns when the
/// latest wrapper statuses hold `missing`, `signatureInvalid`, or
/// `unknownPackage` entries.
struct WrapperStatusCheck: HealthCheck {
    /// The statuses of the last sweep or `listWrappers` pass, keyed by
    /// package ID.
    let statuses: @Sendable () async -> [String: WrapperStatus]

    var id: HealthCheckID { "wrappers.status" }
    var group: HealthGroup { .macApps }
    var requirement: HealthRequirement { .host }
    var cost: HealthCost { .quick }
    var title: LocalizedText {
        LocalizedText(key: "health.wrappers.status", fallback: "Mac app status")
    }

    func run(_ context: HealthContext) async -> HealthResult {
        let current = await statuses()
        let broken = current.filter {
            switch $0.value.state {
            case .missing, .signatureInvalid, .unknownPackage:
                return true
            default:
                return false
            }
        }
        let state: HealthState = broken.isEmpty ? .pass : .warning
        let detail =
            broken.isEmpty
            ? "All Mac apps are in place."
            : "\(broken.count) Mac app(s) are missing, modified, or wrap an uninstalled package: "
                + broken.keys.sorted().joined(separator: ", ")
        return HealthResult(
            id: id,
            group: group,
            state: state,
            title: title,
            detail: detail,
            error: nil,
            fixAvailable: false,
            lastKnown: nil,
            measuredAt: Date()
        )
    }
}

/// The `wrappers.launcher` health check (wrapper.md §14): information for
/// wrappers one launcher-API major behind, warning for two or more.
struct WrapperLauncherCheck: HealthCheck {
    let registry: WrapperRegistry
    /// The launcher API of the installed template (e.g. "1.0").
    let templateLauncherAPI: @Sendable () -> String?

    var id: HealthCheckID { "wrappers.launcher" }
    var group: HealthGroup { .macApps }
    var requirement: HealthRequirement { .host }
    var cost: HealthCost { .quick }
    var title: LocalizedText {
        LocalizedText(key: "health.wrappers.launcher", fallback: "Mac app launcher")
    }

    func run(_ context: HealthContext) async -> HealthResult {
        guard let template = templateLauncherAPI(),
            let templateMajor = Self.apiMajor(template)
        else {
            return HealthResult(
                id: id,
                group: group,
                state: .skipped,
                title: title,
                detail: "No launcher template is installed.",
                error: nil,
                fixAvailable: false,
                lastKnown: nil,
                measuredAt: Date()
            )
        }
        var behindOne = 0
        var behindTwoOrMore = 0
        for entry in await registry.entries() where entry.state == .active {
            guard let major = Self.apiMajor(entry.launcherAPI) else { continue }
            let delta = templateMajor - major
            if delta == 1 {
                behindOne += 1
            } else if delta >= 2 {
                behindTwoOrMore += 1
            }
        }
        let state: HealthState =
            behindTwoOrMore > 0 ? .warning : (behindOne > 0 ? .info : .pass)
        var detail = "Every Mac app uses the current launcher."
        if behindTwoOrMore > 0 {
            detail =
                "\(behindTwoOrMore) Mac app(s) are two or more launcher versions behind "
                + "and can no longer launch."
            if behindOne > 0 {
                detail += " \(behindOne) more are one version behind."
            }
        } else if behindOne > 0 {
            detail = "\(behindOne) Mac app(s) can be updated to the current launcher."
        }
        return HealthResult(
            id: id,
            group: group,
            state: state,
            title: title,
            detail: detail,
            error: nil,
            fixAvailable: false,
            lastKnown: nil,
            measuredAt: Date()
        )
    }

    private static func apiMajor(_ version: String) -> Int? {
        Int(version.split(separator: ".").first ?? "")
    }
}
