import APKStoreCore
import Foundation
import RuntimeAPI

/// The record and settings writes a `setUpdatePolicy` produces (update-system.md
/// §2.1–§2.4). `settingsMode` is written to `settings.json` `update.mode` before
/// the record write, so a crash never turns on automatic updates.
public struct UpdatePolicyResolution: Sendable, Equatable {
    /// The record's new `updateAuthority`.
    public var authority: UpdateAuthority
    /// The value for `settings.json` `update.mode`.
    public var settingsMode: String
    /// The new provider reference, or nil when unchanged or removed.
    public var provider: UpdateProviderRef?
    /// Whether `updateProvider` is cleared.
    public var removeProvider: Bool
    /// Whether the store must fail when the effective record has no provider.
    public var requireProvider: Bool
}

/// The authority rules of update-system.md §2.1–§2.4 for a `setUpdatePolicy` call.
public enum UpdatePolicyRules {
    /// Maps a wire `UpdatePolicy` to the record's authority, settings mode, and
    /// provider change.
    ///
    /// - A `googlePlay` or `external` package refuses every choice
    ///   (`update.authorityDoesNotAllowUpdates`).
    /// - A `manual` choice or a provider removal yields `manual`; attaching a
    ///   provider or choosing `automatic`/`notifyOnly` yields `apkrun` and
    ///   requires a provider (`update.providerNotConfigured`).
    public static func resolve(
        _ policy: UpdatePolicy,
        for record: PackageRecord
    ) throws -> UpdatePolicyResolution {
        if record.updateAuthority == .googlePlay || record.updateAuthority == .external {
            throw UpdateFailure.authorityDoesNotAllowUpdates
        }

        let provider: UpdateProviderRef?
        let removeProvider: Bool
        switch policy.provider {
        case .keep:
            provider = nil
            removeProvider = false
        case .remove:
            provider = nil
            removeProvider = true
        case .set(let spec):
            provider = try providerRef(for: spec)
            removeProvider = false
        }

        let effectiveProvider = removeProvider ? nil : (provider ?? record.updateProvider)
        let authority: UpdateAuthority
        switch (policy.choice, policy.provider) {
        case (.manual, _):
            authority = .manual
        case (_, .remove):
            authority = .manual
        case (.automatic, _), (.notifyOnly, _):
            guard effectiveProvider != nil else {
                throw UpdateFailure.providerNotConfigured
            }
            authority = .apkrun
        }

        return UpdatePolicyResolution(
            authority: authority,
            settingsMode: settingsMode(for: policy.choice),
            provider: provider,
            removeProvider: removeProvider,
            requireProvider: authority == .apkrun)
    }

    /// The `settings.json` `update.mode` a wire choice maps to (§2.3).
    public static func settingsMode(for choice: UpdateChoice) -> String {
        switch choice {
        case .automatic: "automatic"
        case .notifyOnly: "notifyOnly"
        case .manual: "manual"
        }
    }

    /// The wire `UpdateChoice` a record authority and settings mode describe.
    /// Only `apkrun` and `manual` authorities carry a choice (§2.2).
    public static func choice(authority: UpdateAuthority, mode: String?) -> UpdateChoice? {
        switch authority {
        case .googlePlay, .external:
            return nil
        case .manual:
            return .manual
        case .apkrun:
            switch mode {
            case "notifyOnly": return .notifyOnly
            case "manual": return .manual
            default: return .automatic
            }
        }
    }

    /// A wire provider spec parsed into a stored provider reference
    /// (runtime-api.md §9.2). #38 ships `local`; the other schemes land with
    /// their providers (#51, #52, #53).
    public static func providerRef(for spec: ProviderSpec) throws -> UpdateProviderRef {
        // A bare `fdroid` spec names the main repository (§4.5).
        if spec.spec == "fdroid" {
            return try FDroidProvider.providerRef(for: "")
        }
        guard let colon = spec.spec.firstIndex(of: ":") else {
            throw UpdateFailure.providerMetadataInvalid(detail: "provider spec has no scheme")
        }
        let scheme = spec.spec[..<colon]
        let rest = spec.spec[spec.spec.index(after: colon)...]
        switch scheme {
        case "local":
            guard let bookmark = spec.bookmark else {
                throw UpdateFailure.providerMetadataInvalid(
                    detail: "local provider needs a security-scoped bookmark")
            }
            return UpdateProviderRef(
                type: .local,
                configuration: .local(
                    path: String(rest),
                    bookmark: bookmark.base64EncodedString()))
        case "direct":
            return UpdateProviderRef(
                type: .direct,
                configuration: .direct(
                    url: try ProviderRegistry.directURL(String(rest))))
        case "fdroid":
            return try FDroidProvider.providerRef(for: String(rest))
        case "github":
            return try GitHubProvider.providerRef(for: String(rest))
        default:
            throw UpdateFailure.providerMetadataInvalid(
                detail: "unknown provider scheme \"\(scheme)\"")
        }
    }
}
