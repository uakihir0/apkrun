import Foundation

/// The in-process and XPC-facing runtime operations used by clients.
///
/// RuntimeAPI intentionally owns wire-compatible value types instead of importing package-store
/// or runtime implementation modules. RuntimeHost adapts these values to its internal models.
public protocol RuntimePackageService: Sendable {
    /// Copies and inspects APK files, returning a preview ticket without starting Android.
    func importPackage(
        _ request: RuntimeImportPackageRequest,
        files: [FileHandle]
    ) async throws(RuntimeWireError) -> RuntimeImportPreview

    /// Installs a previously inspected import into Android through the runtime's package channel.
    func installImported(
        _ request: RuntimeInstallImportedRequest
    ) async throws(RuntimeWireError) -> RuntimePackageSummary

    /// Uninstalls a package and applies the requested Android-data policy.
    func uninstallPackage(
        _ request: RuntimeUninstallPackageRequest
    ) async throws(RuntimeWireError)

    /// Lists the most recently reconciled packages. This may work while Android is stopped.
    func listPackages(
        _ request: RuntimeListPackagesRequest
    ) async throws(RuntimeWireError) -> RuntimePackageListResult

    /// Returns the package record and the Android facts known to the host.
    func packageInfo(
        _ request: RuntimePackageRequest
    ) async throws(RuntimeWireError) -> RuntimePackageDetails
}

/// Runtime session operations. Package identity is resolved by the runtime before launch.
public protocol RuntimeSessionService: Sendable {
    /// Starts an application session and returns its initial runtime state.
    func launch(
        _ request: RuntimeLaunchRequest
    ) async throws(RuntimeWireError) -> RuntimeLaunchResult

    /// Ends the application's session and asks Android to stop its tasks.
    func terminate(
        _ request: RuntimeTerminateRequest
    ) async throws(RuntimeWireError) -> RuntimeTerminateResult
}

/// The package and application session operations shared by embedded and daemon clients.
public protocol RuntimeService: RuntimePackageService, RuntimeSessionService {}
