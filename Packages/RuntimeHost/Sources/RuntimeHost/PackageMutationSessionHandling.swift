import RuntimeAPI

/// Queries package-session activity and closes an app session before package removal.
protocol PackageMutationSessionHandling: Sendable {
    func hasActiveSession(packageID: RuntimePackageID) async -> Bool
    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError)
    /// GU4: when the package's last session ended; `nil` when none is known.
    func lastSessionEnd(packageID: RuntimePackageID) async -> ContinuousClock.Instant?
    /// §7.3 Update Now: end the package's live session with `.updating`.
    func endSessionForUpdate(packageID: RuntimePackageID) async
    /// §7.3 Update Now: launch the package again after the install.
    func reopenPackageSession(packageID: RuntimePackageID) async throws
}
