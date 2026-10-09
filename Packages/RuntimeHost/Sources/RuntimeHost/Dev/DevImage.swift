import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore

/// `apkrun dev image install <bundle>`: installs a development bundle as the current image
/// (cli.md §5; android-image.md §10.3; #065).
public struct DevImage: Sendable {
    /// Creates the development image installer.
    public init() {}

    /// Verifies the bundle directory, installs it under `Images/<version>/`, and makes it current.
    /// An instance is provisioned when there is none, and the instance lock is held throughout.
    public func install(
        bundleURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        onEvent: @escaping @Sendable (DevBootEvent) -> Void
    ) async throws {
        let paths = APKRunPaths(allowingHomeOverride: true, environment: environment)
        let lock = try InstanceLock.acquire(paths: paths, owner: .apkrunDev)
        defer { lock.close() }
        let diagnostics = DiagnosticsContext.live(paths: paths)

        let images = ImageStore(paths: paths, trust: .standard(), diagnostics: diagnostics)
        try await images.removeOrphanedInstalls()
        let image = try await images.install(from: .directory(bundleURL))
        onEvent(.message("installed image \(image.version.description) from \(bundleURL.path)"))

        let store = InstanceStore(paths: paths, diagnostics: diagnostics)
        if let existing = try await store.load(image: image) {
            if existing.imageVersion != image.version {
                onEvent(
                    .message(
                        "the instance uses \(existing.imageVersion.description); `apkrun dev boot --reset` moves it to \(image.version.description)"
                    ))
            }
        } else {
            _ = try await store.provision(image: image, sizing: .default)
            onEvent(.message("provisioned a new Android instance"))
        }
    }
}
