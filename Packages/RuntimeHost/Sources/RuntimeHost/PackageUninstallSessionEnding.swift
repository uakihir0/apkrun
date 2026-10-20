import RuntimeAPI

/// Ends the package's host-owned app session with the package-removal reason before Android
/// removes its tasks.
protocol PackageUninstallSessionEnding: Sendable {
    func endSessionForPackageUninstall(_ request: RuntimeTerminateRequest) async throws(RuntimeWireError)
}
