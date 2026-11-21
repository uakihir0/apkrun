import AppKit
import RuntimeAPI
import RuntimeClient

/// §3.7 first-launch tasks after an APKRun update
/// (runtime-maintenance.md §3.7). Runs from `applicationDidFinishLaunching`,
/// before any view uses the runtime.
@MainActor
final class SelfUpdateController {
    /// `lastLaunchedBuild` in UserDefaults, per §3.7 steps 1 and 6.
    static let lastLaunchedBuildKey = "lastLaunchedBuild"

    /// The maintenance endpoint client; injectable for tests.
    private let maintenance: () throws -> any MaintenanceControlling
    /// The control client used for the wrapper refresh prompt (§3.7 step 5).
    private let control: () throws -> RuntimeControlClient
    /// Registers apkrund; injectable for tests.
    private let registerAgent: @MainActor () throws -> Bool

    init(
        maintenance: (() throws -> any MaintenanceControlling)? = nil,
        control: (() throws -> RuntimeControlClient)? = nil,
        registerAgent: (@MainActor () throws -> Bool)? = nil
    ) {
        self.maintenance = maintenance ?? {
            try MaintenanceControlClient(clientKind: .app)
        }
        self.control = control ?? {
            try RuntimeControlClient(clientKind: .app)
        }
        self.registerAgent = registerAgent ?? {
            try RuntimeRegistrationCommand.registerRuntimeAgentIfNeeded()
        }
    }

    /// Runs §3.7 once per build. Returns the count of wrappers that need a
    /// refresh so the app can show the §3.7 step 5 prompt; `nil` means this
    /// build already launched before and nothing ran.
    @discardableResult
    func completeUpdateIfNeeded() async throws -> Int? {
        let ownBuild = Int(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        ) ?? 0
        let last = UserDefaults.standard.integer(forKey: Self.lastLaunchedBuildKey)
        guard ownBuild != last else { return nil }

        // Step 2: agent registration (AgentRegistrar, §3.7). The existing
        // registration path keeps a pending approval and re-registers only
        // when the embedded plist hash changed.
        _ = try registerAgent()

        // Step 4: end the daemon's finishing wait (§3.6). Fails silently when
        // no marker exists — an uncorrelated launch has nothing to complete.
        if let client = try? maintenance() {
            _ = try? await client.completeHostUpdate()
        }

        // Step 5: launcher refresh prompt (§3.7, wrapper.md §9.4).
        var needsRefresh = 0
        if let client = try? control() {
            let wrappers = (try? await client.listWrappers()) ?? []
            needsRefresh = wrappers.filter { !$0.refreshReasons.isEmpty }.count
        }

        // Step 6: record the launch.
        UserDefaults.standard.set(ownBuild, forKey: Self.lastLaunchedBuildKey)
        return needsRefresh
    }
}

/// The slice of the maintenance endpoint `SelfUpdateController` uses
/// (test seam; `MaintenanceControlClient` conforms).
@MainActor
protocol MaintenanceControlling {
    func completeHostUpdate() async throws -> MaintenanceControlReply
}

extension MaintenanceControlClient: MaintenanceControlling {}

/// The §3.7 step 5 launcher refresh prompt: "‹N› Mac apps need to be updated
/// to work with this version of APKRun." with Update Now / Later.
enum SelfUpdatePrompt {
    @MainActor static func show(wrapperCount: Int) {
        let alert = NSAlert()
        alert.messageText =
            "\(wrapperCount) Mac app\(wrapperCount == 1 ? "" : "s") need"
            + " to be updated to work with this version of APKRun."
        alert.informativeText =
            "Updating rebuilds the launchers; your Android apps and data stay untouched."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        alert.alertStyle = .informational
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Start the batch refresh the same way Home's Update All does.
        Task { @MainActor in
            guard let client = try? RuntimeControlClient(clientKind: .app) else { return }
            _ = try? await client.refreshAllWrappers(
                scope: .needingRefresh,
                launcherOnly: false,
                operationID: OperationID())
        }
    }
}
