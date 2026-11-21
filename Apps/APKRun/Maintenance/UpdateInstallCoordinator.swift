import AppKit
import RuntimeAPI
import RuntimeClient

/// The slice of the maintenance endpoint the install handshake uses
/// (test seam; `MaintenanceControlClient` conforms).
protocol HostUpdateCoordinating: Sendable {
    func status() async throws -> MaintenanceStatus
    func prepareForHostUpdate(_ request: HostUpdateRequest) async throws -> MaintenanceControlReply
    func abortHostUpdate() async throws -> MaintenanceControlReply
}

extension MaintenanceControlClient: HostUpdateCoordinating {}

/// The §3.5 install handshake: Sparkle holds the update while APKRun empties
/// the daemon, then calls Sparkle's block so it quits, replaces the bundle,
/// and relaunches (runtime-maintenance.md §3.5).
@MainActor
final class UpdateInstallCoordinator {
    /// `prepareForHostUpdate` may take up to this long while apkrund drains
    /// sessions and stops Android (§3.5 step 4).
    static let prepareTimeout: Duration = .seconds(180)

    /// Pending state while §3.5.1 waits for apps to close; Settings shows it.
    private(set) var waitingForAppsToClose = false
    /// The update Sparkle installs on quit, for the Settings status line.
    private(set) var pendingOnQuit: AvailableRelease?

    private let maintenance: () throws -> any HostUpdateCoordinating
    private let terminateMenuBar: () -> Void
    private var waitingTask: Task<Void, Never>?

    init(
        maintenance: (() throws -> any HostUpdateCoordinating)? = nil,
        terminateMenuBar: (() -> Void)? = nil
    ) {
        self.maintenance =
            maintenance ?? {
                try MaintenanceControlClient(clientKind: .app)
            }
        self.terminateMenuBar =
            terminateMenuBar ?? {
                for app in NSRunningApplication.runningApplications(
                    withBundleIdentifier: "io.apkrun.APKRunMenuBar")
                {
                    app.terminate()
                }
            }
    }

    /// Records the release Sparkle will install on quit (§3.2).
    func notePendingOnQuit(_ release: AvailableRelease) {
        pendingOnQuit = release
    }

    /// Whether sessions or background work still run (§3.5 step 3).
    private func workRemains() async -> Bool {
        guard let status = try? await maintenance().status() else { return false }
        return !(status.sessions.isEmpty && status.backgroundTasks.isEmpty)
            || !status.activities.isEmpty
            || status.imageMigrating
    }

    /// Runs the handshake for Sparkle's postponed `installHandler`
    /// (§3.5 steps 2–6). `release` is the item being installed.
    func beginInstall(release: AvailableRelease, installHandler: @escaping () -> Void)
        async
    {
        var closeSessions = false
        if await workRemains() {
            switch installPrompt(version: release.version) {
            case .cancel:
                return
            case .whenClosed:
                waitingForAppsToClose = true
                waitForAppsToClose(release: release, installHandler: installHandler)
                return
            case .closeAndInstall:
                closeSessions = true
            }
        }
        await prepareAndInstall(
            release: release,
            closeSessions: closeSessions,
            installHandler: installHandler)
    }

    /// §3.5.1: watch sessions and background work until empty, then prepare
    /// with `closeSessions = false`.
    private func waitForAppsToClose(
        release: AvailableRelease, installHandler: @escaping () -> Void
    ) {
        waitingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if await self?.workRemains() == false {
                    self?.waitingForAppsToClose = false
                    await self?.prepareAndInstall(
                        release: release, closeSessions: false, installHandler: installHandler)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// §3.5.1's "Install Now…" returns to the dialog: cancel the wait and run
    /// the handshake again.
    func installNow(release: AvailableRelease, installHandler: @escaping () -> Void)
        async
    {
        waitingTask?.cancel()
        waitingForAppsToClose = false
        await beginInstall(release: release, installHandler: installHandler)
    }

    enum InstallChoice {
        case closeAndInstall
        case whenClosed
        case cancel
    }

    /// §3.5 step 3's dialog.
    func installPrompt(version: String) -> InstallChoice {
        let alert = NSAlert()
        alert.messageText = "Android apps are still open"
        alert.informativeText =
            "APKRun \(version) is ready to install. Close your Android apps to"
            + " install it now, or install it when they are closed."
        alert.addButton(withTitle: "Close Apps and Install")
        alert.addButton(withTitle: "Install When Apps Are Closed")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .closeAndInstall
        case .alertSecondButtonReturn: return .whenClosed
        default: return .cancel
        }
    }

    /// §3.5 steps 4–6. On failure the update stays downloaded and a "Try
    /// Again" alert offers to retry; `abortHostUpdate` clears any marker.
    private func prepareAndInstall(
        release: AvailableRelease,
        closeSessions: Bool,
        installHandler: @escaping () -> Void
    ) async {
        do {
            let client = try maintenance()
            let reply = try await withThrowingTaskGroup(
                of: MaintenanceControlReply.self
            ) { group in
                group.addTask {
                    try await client.prepareForHostUpdate(
                        HostUpdateRequest(
                            targetVersion: release.version,
                            targetBuild: release.build,
                            closeSessions: closeSessions))
                }
                group.addTask {
                    try await Task.sleep(for: Self.prepareTimeout)
                    throw CancellationError()
                }
                let result = try await group.next()
                group.cancelAll()
                guard let result else { throw CancellationError() }
                return result
            }
            if let error = reply.error {
                throw RuntimeWireError(
                    domain: "maintenance", code: error.code, message: error.message)
            }
        } catch {
            _ = try? await maintenance().abortHostUpdate()
            if retryAlert(message: Self.describe(error)) {
                await prepareAndInstall(
                    release: release, closeSessions: closeSessions,
                    installHandler: installHandler)
            }
            return
        }
        // §3.5 step 5: the menu bar exits before the bundle is replaced.
        terminateMenuBar()
        installHandler()
    }

    /// The abort used after a failed prepare or a Sparkle abort
    /// (§3.2 `didAbortWithError` path). Idempotent on the daemon side.
    func abortPendingHostUpdate() async {
        _ = try? await maintenance().abortHostUpdate()
    }

    private func retryAlert(message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "APKRun couldn't be updated."
        alert.informativeText = message
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func describe(_ error: any Error) -> String {
        if let wire = error as? RuntimeWireError { return wire.message }
        return error.localizedDescription
    }
}
