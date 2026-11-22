import AppKit
import Foundation
import RuntimeAPI
import RuntimeClient

/// Screen N of the portable wrapper flow (M07-mac-app-wrappers.md,
/// wrapper-json.md §3.4): a portable wrapper carries its package in
/// `Contents/Resources/bootstrap/`. When the package is not installed the
/// launcher offers **Install from This App**, runs `importBootstrap`, and
/// then retries `openSession` (the session flow itself is #45).
@MainActor
final class BootstrapInstallController {
    /// The decoded `bootstrap.json` — the fields the prompt and the wire
    /// call need; the full schema is WrapperCore's `BootstrapDocument`.
    private struct Payload: Decodable {
        struct File: Decodable {
            var name: String
        }
        var packageId: String
        var versionCode: Int64
        var versionName: String?
        var files: [File]
    }

    /// `Contents/Resources/bootstrap/bootstrap.json` + its payload files,
    /// when this wrapper is portable and readable.
    private var bundle: (directory: URL, json: Data, payload: Payload)? {
        let directory = Bundle.main.resourceURL?
            .appendingPathComponent("bootstrap")
        guard let directory,
            let json = try? Data(
                contentsOf: directory.appendingPathComponent("bootstrap.json")),
            let payload = try? JSONDecoder().decode(Payload.self, from: json)
        else {
            return nil
        }
        return (directory, json, payload)
    }

    /// The package this launcher wraps, when a portable bootstrap payload
    /// carries it — used to preselect the diagnostics report's focus
    /// (diagnostics.md §8.5).
    var bundledPackageID: String? { bundle?.payload.packageId }

    /// Whether the bundled package is missing from the store and the
    /// screen-N prompt applies (wrapper-json.md §3.4 B2).
    func needsInstall() async -> Bool {
        guard let bundle else { return false }
        guard let packageID = RuntimePackageID(rawValue: bundle.payload.packageId),
            let client = try? RuntimeControlClient(clientKind: .launcher)
        else {
            return false
        }
        do {
            let details = try await client.packageInfo(packageID: packageID)
            return details.summary.state != .installed
        } catch {
            // The store has no record of the package — offer the install.
            return true
        }
    }

    /// Runs the screen-N prompt and, on approval, `importBootstrap`.
    /// Returns true when the bundled package was installed (the caller
    /// should retry the launch).
    func offerInstall() async -> Bool {
        guard let bundle, await needsInstall() else { return false }
        let payload = bundle.payload
        let appName =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? payload.packageId
        let version = payload.versionName ?? String(payload.versionCode)
        let alert = NSAlert()
        alert.messageText = LauncherStrings.text("Install \(appName) \(version) from this Mac app?")
        alert.informativeText =
            "This Mac app contains the Android app. Install it to continue."
        alert.addButton(withTitle: LauncherStrings.text("Install from This App"))
        alert.addButton(withTitle: LauncherStrings.text("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let handles = try payload.files.map { file in
                try FileHandle(
                    forReadingFrom: bundle.directory
                        .appendingPathComponent(file.name))
            }
            defer {
                for handle in handles {
                    try? handle.close()
                }
            }
            let client = try RuntimeControlClient(clientKind: .launcher)
            _ = try await client.importBootstrap(
                bundleID: Bundle.main.bundleIdentifier ?? "",
                bootstrapJSON: bundle.json,
                files: handles)
            return true
        } catch {
            let failure = NSAlert()
            failure.messageText = LauncherStrings.text("\(appName) could not be installed.")
            failure.informativeText = String(describing: error)
            failure.runModal()
            return false
        }
    }
}
