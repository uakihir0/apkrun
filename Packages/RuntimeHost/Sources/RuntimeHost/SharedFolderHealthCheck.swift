import DiagnosticsCore
import Foundation
import RuntimeAPI

/// Reports whether configured shared-folder roots are available to apkrund.
public struct SharedFolderHealthCheck: HealthCheck {
    /// Reads the configured shared-folder roots from the daemon-owned service.
    public typealias SharedFoldersProvider = @Sendable () async throws -> [RuntimeAPI.SharedFolder]

    /// Stable identifier used by `apkrun doctor`.
    public let id: HealthCheckID = "integrations.sharedFolders"

    /// The diagnostics report section that owns this check.
    public let group: HealthGroup = .integrations

    /// Shared-folder configuration is owned by the daemon.
    public let requirement: HealthRequirement = .daemon

    /// Listing roots is a bounded configuration read.
    public let cost: HealthCost = .quick

    private let sharedFolders: SharedFoldersProvider

    /// Creates the check with a daemon-owned shared-folder listing provider.
    public init(sharedFolders: @escaping SharedFoldersProvider) {
        self.sharedFolders = sharedFolders
    }

    /// Performs a path-free availability check over the configured roots.
    public func run(_ context: HealthContext) async -> HealthResult {
        let roots: [RuntimeAPI.SharedFolder]
        do {
            roots = try await sharedFolders()
        } catch {
            return result(
                context,
                state: .warning,
                detail: "Shared-folder settings are unavailable."
            )
        }

        let unavailable = roots.filter { $0.availability != .available }
        guard let firstUnavailable = unavailable.first else {
            let detail =
                roots.isEmpty
                ? "No shared folders are configured."
                : "All configured shared folders are available."
            return result(context, state: .pass, detail: detail)
        }

        return result(
            context,
            state: .warning,
            detail: "Shared-folder access needs attention: \(firstUnavailable.availability.rawValue).",
            error: Self.folderUnavailableError(for: firstUnavailable.availability)
        )
    }

    private func result(
        _ context: HealthContext,
        state: HealthState,
        detail: String,
        error: ErrorInfo? = nil
    ) -> HealthResult {
        HealthResult(
            id: id,
            group: group,
            state: state,
            title: LocalizedText(key: id, fallback: "Shared folders"),
            detail: detail,
            error: error,
            measuredAt: context.clock.now
        )
    }

    private static func folderUnavailableError(
        for availability: RuntimeAPI.SharedFolderAvailability
    ) -> ErrorInfo {
        let code = "integration.folderUnavailable"
        let parameters: [String: ErrorParameter] = [
            "file": .fileName("shared folder"),
            "reason": .text(availability.rawValue),
        ]
        let entry = ErrorCatalog.entry(for: code)
        let variant = entry?.variants[availability.rawValue]
        let message =
            variant?.message?["en"]
            ?? entry?.message?["en"]
            ?? "APKRun can't access a shared folder."
        let remediation =
            variant?.remediation?["en"]
            ?? "Check Settings → Files and reconnect or remove the unavailable folder."

        return ErrorInfo(
            code: code,
            message: LocalizedText(key: code, parameters: parameters, fallback: message),
            remediation: LocalizedText(
                key: "\(code).remediation",
                parameters: parameters,
                fallback: remediation
            )
        )
    }
}
