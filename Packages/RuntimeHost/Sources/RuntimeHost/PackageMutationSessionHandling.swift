import RuntimeAPI

/// Queries package-session activity and closes an app session before package removal.
protocol PackageMutationSessionHandling: Sendable {
    func hasActiveSession(packageID: RuntimePackageID) async -> Bool
    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError)
}
