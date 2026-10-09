import DiagnosticsCore
import Foundation

/// The bundled development Guest Agent: its APK and its version record, which `scripts/build-guest.sh` writes next to
/// each other (guest-components.md §3.1).
public struct GuestAgentBundle: Equatable, Sendable {
    /// The APK, `apkrun-guest.apk`.
    public let apk: URL
    /// The package name, `io.apkrun.guest`.
    public let packageName: String
    /// The `versionCode` of the APK, which the host compares with the installed one.
    public let versionCode: Int
    /// The `versionName` of the APK.
    public let versionName: String

    /// Creates a bundle from its parts.
    public init(apk: URL, packageName: String, versionCode: Int, versionName: String) {
        self.apk = apk
        self.packageName = packageName
        self.versionCode = versionCode
        self.versionName = versionName
    }

    /// Reads the bundle in `directory`: `apkrun-guest.apk` and `apkrun-guest.json`. A missing file, or a record that
    /// does not name the Guest Agent package, is `bundleMissing`.
    public static func load(directory: URL) throws(GuestAgentFailure) -> GuestAgentBundle {
        let apk = directory.appendingPathComponent("apkrun-guest.apk")
        let record = directory.appendingPathComponent("apkrun-guest.json")
        guard FileManager.default.fileExists(atPath: apk.path),
            let data = try? Data(contentsOf: record),
            let decoded = try? JSONDecoder().decode(Record.self, from: data),
            decoded.packageName == "io.apkrun.guest",
            decoded.versionCode > 0
        else {
            throw .bundleMissing
        }
        return GuestAgentBundle(
            apk: apk,
            packageName: decoded.packageName,
            versionCode: decoded.versionCode,
            versionName: decoded.versionName
        )
    }

    private struct Record: Decodable {
        let packageName: String
        let versionCode: Int
        let versionName: String
    }
}

/// Installs, starts, and stops the development Guest Agent through ADB (guest-components.md §3.1, §3.3).
public actor GuestAgentProvisioner {
    /// The process name of the daemon, which `--nice-name` sets (guest-components.md §3.2).
    public static let processName = "apkrun_guestd"

    private let adb: AdbClient
    private let bundle: GuestAgentBundle

    /// Creates the provisioner for one bundle.
    public init(adb: AdbClient, bundle: GuestAgentBundle) {
        self.adb = adb
        self.bundle = bundle
    }

    /// Installs the bundled agent (guest-components.md §3.1). The install runs on every start, even when the versionCode
    /// is the same, so that a rebuilt agent takes effect and so that Android decides on the signer. An installed agent
    /// that another signer made is refused with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. Then the installed copy is
    /// removed, and the bundled one is installed. A newer installed agent is removed first, because `install -r` does
    /// not downgrade. The agent keeps no user data in development mode, so the removal is safe. A refusal that is not
    /// recovered is `installFailed` with Android's reason (IR-423, IR-424, IR-425).
    public func install() async throws(GuestAgentFailure) {
        let installed: Int?
        do {
            let listing = try await adb.listPackages(matching: bundle.packageName)
            installed = listing.first { $0.name == bundle.packageName }?.versionCode
        } catch {
            throw .adb(error)
        }
        do {
            if let installed, installed > bundle.versionCode {
                try await adb.uninstall(packageName: bundle.packageName)
            }
            try await installBundle()
        } catch {
            if case .packageRejected(_, let reason) = error {
                throw .installFailed(reason: reason)
            }
            throw .adb(error)
        }
    }

    /// Starts the agent. A copy that is still running is terminated first, so that the new one can bind its sockets.
    public func startAgent() async throws(GuestAgentFailure) {
        do {
            if try await adb.processID(named: Self.processName) != nil {
                try await adb.terminateProcess(named: Self.processName)
                try await waitForExit(attempts: 30)
            }
            try await adb.startGuestAgent(packageName: bundle.packageName)
        } catch {
            throw .adb(error)
        }
    }

    /// Whether an agent process runs (`pidof`).
    public func isRunning() async throws(GuestAgentFailure) -> Bool {
        do {
            return try await adb.processID(named: Self.processName) != nil
        } catch {
            throw .adb(error)
        }
    }

    /// Stops the agent process, if one runs.
    public func stopAgent() async {
        try? await adb.terminateProcess(named: Self.processName)
    }

    private func installBundle() async throws(AdbFailure) {
        do {
            try await adb.install(apk: bundle.apk, allowTestOnly: true)
        } catch AdbFailure.packageRejected(_, let reason) where reason == "INSTALL_FAILED_UPDATE_INCOMPATIBLE" {
            try await adb.uninstall(packageName: bundle.packageName)
            try await adb.install(apk: bundle.apk, allowTestOnly: true)
        }
    }

    /// Waits until no agent process is left, polling `pidof` every 100 ms.
    private func waitForExit(attempts: Int) async throws(AdbFailure) {
        for _ in 0..<attempts {
            if try await adb.processID(named: Self.processName) == nil {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
