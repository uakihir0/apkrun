import Foundation
import RuntimeAPI

/// Coordinates APKRun self-updates (runtime-maintenance.md §3.5–§3.7).
///
/// Owns the daemon's `HostState`, the `Runtime/maintenance.json` marker, and
/// the maintenance endpoint's operations. The state transitions:
///
/// - `prepareForHostUpdate` → `updating(targetBuild)`, writes the marker,
///   publishes `hostStateChanged`.
/// - `abortHostUpdate` → `normal`, deletes the marker.
/// - `completeHostUpdate` → `normal` after a successful replacement
///   (§3.6 finishing step).
/// - `restartForUpdate` → allows the daemon to exit once idle while in
///   `restartPending`.
///
/// `BundleWatcher` moves the daemon into `restartPending` when the on-disk
/// bundle build changes underneath it.
actor MaintenanceService {
    private var hostState: HostState = .normal
    private let markerURL: URL
    private let version: String
    private let build: Int
    private let publish: @Sendable (MaintenanceEvent) -> Void
    private let sessionsProvider: @Sendable () async -> [RuntimePackageID]
    private let backgroundTasksProvider: @Sendable () async -> [RuntimePackageID]
    private let activitiesProvider: @Sendable () async -> [ActivityKind]
    private let imageMigratingProvider: @Sendable () async -> Bool
    private let idleAndExit: @Sendable () -> Void

    init(
        markerFile: URL,
        version: String,
        build: Int,
        publish: @escaping @Sendable (MaintenanceEvent) -> Void,
        sessionsProvider: @escaping @Sendable () async -> [RuntimePackageID],
        backgroundTasksProvider: @escaping @Sendable () async -> [RuntimePackageID],
        activitiesProvider: @escaping @Sendable () async -> [ActivityKind],
        imageMigratingProvider: @escaping @Sendable () async -> Bool,
        idleAndExit: @escaping @Sendable () -> Void
    ) {
        markerURL = markerFile
        self.version = version
        self.build = build
        self.publish = publish
        self.sessionsProvider = sessionsProvider
        self.backgroundTasksProvider = backgroundTasksProvider
        self.activitiesProvider = activitiesProvider
        self.imageMigratingProvider = imageMigratingProvider
        self.idleAndExit = idleAndExit
    }

    /// The current host state.
    var state: HostState { hostState }

    /// A status snapshot for `maintenanceStatus` and diagnostics (§3.6).
    func status() async -> MaintenanceStatus {
        MaintenanceStatus(
            version: version,
            build: build,
            hostState: hostState,
            sessions: await sessionsProvider(),
            backgroundTasks: await backgroundTasksProvider(),
            activities: await activitiesProvider(),
            imageMigrating: await imageMigratingProvider(),
            marker: readMarker()
        )
    }

    /// Begins a coordinated host update (§3.5 step 4).
    func prepareForHostUpdate(_ request: HostUpdateRequest) async throws(RuntimeWireError) {
        switch hostState {
        case .updating:
            throw .maintenance("hostUpdateAlreadyPending", message: "A host update is already in progress.")
        case .restartPending:
            throw .maintenance("hostRestartPending", message: "APKRun must restart before it can update again.")
        case .normal, .unknown:
            break
        }
        if !request.closeSessions, await !sessionsProvider().isEmpty {
            throw .maintenance(
                "hostUpdateSessionsOpen",
                message: "Android apps are still open; close them or allow APKRun to close them.")
        }
        let marker = HostUpdateMarker(
            fromVersion: version,
            fromBuild: build,
            targetVersion: request.targetVersion,
            targetBuild: request.targetBuild,
            createdAt: Date(),
            operationID: UUID()
        )
        do {
            try writeMarker(marker)
        } catch {
            throw .maintenance(
                "hostUpdateMarkerFailed",
                message: "Could not write the host-update marker.",
                remediation: "Check permissions on the APKRun runtime directory and retry.")
        }
        hostState = .updating(targetBuild: request.targetBuild)
        publish(.hostStateChanged(hostState))
    }

    /// Cancels a coordinated update (§3.5 abort path).
    func abortHostUpdate() {
        guard case .updating = hostState else { return }
        removeMarker()
        hostState = .normal
        publish(.hostStateChanged(hostState))
    }

    /// Finishes a coordinated update once the new build confirms it (§3.6).
    func completeHostUpdate() {
        removeMarker()
        guard hostState != .normal else { return }
        hostState = .normal
        publish(.hostStateChanged(hostState))
    }

    /// Lets the daemon exit once idle (`restartPending`).
    func restartForUpdate(_ request: RestartForUpdateRequest) async throws(RuntimeWireError) {
        guard case .restartPending = hostState else {
            throw .maintenance("hostUpdateNotPending", message: "No host restart is pending.")
        }
        if !request.closeSessions, await !sessionsProvider().isEmpty {
            throw .maintenance(
                "hostUpdateSessionsOpen",
                message: "Android apps are still open; close them or allow APKRun to close them.")
        }
        idleAndExit()
    }

    /// Moves the daemon into `restartPending` (BundleWatcher, §3.7).
    func noteBundleReplaced(bundleBuild: Int?) {
        guard case .normal = hostState else { return }
        hostState = .restartPending(bundleBuild: bundleBuild)
        publish(.hostStateChanged(hostState))
    }

    // MARK: - Marker file

    private func readMarker() -> HostUpdateMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(HostUpdateMarker.self, from: data)
    }

    private func writeMarker(_ marker: HostUpdateMarker) throws {
        let data = try JSONEncoder().encode(marker)
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: markerURL, options: .atomic)
    }

    private func removeMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
