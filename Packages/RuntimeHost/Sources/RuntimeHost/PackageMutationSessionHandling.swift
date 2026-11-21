import RuntimeAPI
import RuntimeCore

/// Queries package-session activity and closes an app session before package removal.
/// A session or background-task event the update gate reacts to
/// (update-system.md §7.2 triggers).
enum PackageSessionActivity: Sendable, Equatable {
    /// A session for the package started.
    case started
    /// A session for the package ended; GU4's 15-second timer starts here.
    case ended
    /// A keepRunning task for the package ended (GU3 re-check).
    case taskEnded
}

protocol PackageMutationSessionHandling: Sendable {
    func hasActiveSession(packageID: RuntimePackageID) async -> Bool
    /// GU3: the package owns a keepRunning task (update-system.md §7.1).
    func hasBackgroundActivity(packageID: RuntimePackageID) async -> Bool
    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError)
    /// GU4: when the package's last session ended; `nil` when none is known.
    func lastSessionEnd(packageID: RuntimePackageID) async -> ContinuousClock.Instant?
    /// §7.2 triggers: every session start/end and keepRunning task end
    /// reaches `observer`. Observers are retained for the service's life.
    func observeSessionActivity(
        _ observer: @escaping @Sendable (RuntimePackageID, PackageSessionActivity) -> Void
    ) async
    /// §7.3 Update Now: end the package's live session with `.updating`.
    func endSessionForUpdate(packageID: RuntimePackageID, reason: SessionEndReason) async
    /// §7.3 Update Now: launch the package again after the install.
    func reopenPackageSession(packageID: RuntimePackageID) async throws
}

extension PackageMutationSessionHandling {
    /// Test doubles and services without keepRunning tasks report none.
    func hasBackgroundActivity(packageID: RuntimePackageID) async -> Bool { false }
    /// No session history means no recent session (GU4 treats nil as long ago).
    func lastSessionEnd(packageID: RuntimePackageID) async -> ContinuousClock.Instant? { nil }
    /// A service without an activity source emits nothing.
    func observeSessionActivity(
        _ observer: @escaping @Sendable (RuntimePackageID, PackageSessionActivity) -> Void
    ) async {}
    /// Ending sessions is a no-op when nothing can run sessions.
    func endSessionForUpdate(packageID: RuntimePackageID, reason: SessionEndReason) async {}
    /// Reopening is a no-op when the service cannot launch sessions.
    func reopenPackageSession(packageID: RuntimePackageID) async throws {}
}
