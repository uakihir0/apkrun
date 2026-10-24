@preconcurrency import AppKit
import Foundation
import RuntimeAPI

/// Opens a fresh generic launcher process for a package without moving launcher policy into the daemon.
struct WorkspaceOpener: Sendable {
    let launcherBundleURL: URL

    func open(packageID: RuntimePackageID) async throws(RuntimeWireError) {
        guard FileManager.default.fileExists(atPath: launcherBundleURL.path),
            launcherBundleURL.pathExtension == "app"
        else {
            throw Self.launcherUnavailableError
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Task { @MainActor [launcherBundleURL] in
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.arguments = ["--package", packageID.rawValue]
                    configuration.createsNewApplicationInstance = true
                    NSWorkspace.shared.openApplication(at: launcherBundleURL, configuration: configuration) {
                        _, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        } catch {
            throw Self.launcherUnavailableError
        }
    }

    private static let launcherUnavailableError = RuntimeWireError.runtime(
        "serviceUnavailable",
        message: "APKRun couldn't open the app launcher.",
        remediation: "Restart APKRun and try again."
    )
}
