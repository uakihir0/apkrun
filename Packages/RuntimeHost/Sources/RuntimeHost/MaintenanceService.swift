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
    private var selfUpdate: SelfUpdateStatus
    private let markerURL: URL
    private let version: String
    private let build: Int
    private let publish: @Sendable (MaintenanceEvent) -> Void
    private let sessionsProvider: @Sendable () async -> [RuntimePackageID]
    private let backgroundTasksProvider: @Sendable () async -> [RuntimePackageID]
    private let activitiesProvider: @Sendable () async -> [ActivityKind]
    private let imageMigratingProvider: @Sendable () async -> Bool
    private let endSessions: @Sendable () async -> Void
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
        endSessions: @escaping @Sendable () async -> Void,
        idleAndExit: @escaping @Sendable () -> Void
    ) {
        markerURL = markerFile
        self.version = version
        self.build = build
        selfUpdate = SelfUpdateStatus(
            currentVersion: version,
            currentBuild: build)
        self.publish = publish
        self.sessionsProvider = sessionsProvider
        self.backgroundTasksProvider = backgroundTasksProvider
        self.activitiesProvider = activitiesProvider
        self.imageMigratingProvider = imageMigratingProvider
        self.endSessions = endSessions
        self.idleAndExit = idleAndExit
        // A marker left on disk means a host update was in flight when the
        // daemon last exited (§3.6). An older bundle stays `updating` and
        // watches the marker until it disappears or reaches 10 minutes; an
        // older marker is dropped. A bundle at or past `targetBuild` is the
        // new build: it keeps `updating` for at most 60 seconds while it
        // waits for `completeHostUpdate` from the new APKRun.app.
        if let marker = Self.readMarker(at: markerURL) {
            if build < marker.targetBuild {
                if Date().timeIntervalSince(marker.createdAt) < Self.abandonedMarkerAge {
                    hostState = .updating(targetBuild: marker.targetBuild)
                    Task { await self.watchAbandonedMarker() }
                } else {
                    try? FileManager.default.removeItem(at: markerURL)
                }
            } else {
                hostState = .updating(targetBuild: marker.targetBuild)
                Task { await self.expireFinishingMarker(marker) }
            }
        }
    }

    /// §3.6: how long a surviving marker holds an older bundle in `updating`.
    private static let abandonedMarkerAge: TimeInterval = 10 * 60
    /// §3.6: how long the new build waits for `completeHostUpdate`.
    private static let finishingMarkerAge: TimeInterval = 60

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
        if request.targetBuild <= build {
            throw .maintenance(
                "selfUpdateNotNewer",
                message: "The update is not newer than the running build.")
        }
        if await !sessionsProvider().isEmpty {
            if !request.closeSessions {
                throw .maintenance(
                    "hostUpdateSessionsOpen",
                    message: "Android apps are still open; close them or allow APKRun to close them.")
            }
            // `closeSessions` ends every open session before the marker goes
            // on disk; without it Sparkle would replace the runtime bundle
            // while Android still runs (§3.5 step 3).
            await endSessions()
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
    /// A call with no marker on disk is not the new build confirming: it
    /// must not cancel `restartPending`.
    func completeHostUpdate() {
        guard readMarker() != nil else { return }
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
        if await !sessionsProvider().isEmpty {
            if !request.closeSessions {
                throw .maintenance(
                    "hostUpdateSessionsOpen",
                    message: "Android apps are still open; close them or allow APKRun to close them.")
            }
            await endSessions()
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

    /// §3.6 wait loop of an older bundle: poll the marker every 2 seconds.
    /// A removed marker (aborted or completed) or a 10-minute-old one lets
    /// the daemon exit; the next start is `normal`.
    private func watchAbandonedMarker() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard let marker = readMarker() else {
                idleAndExit()
                return
            }
            if Date().timeIntervalSince(marker.createdAt) >= Self.abandonedMarkerAge {
                removeMarker()
                hostState = .normal
                publish(.hostStateChanged(hostState))
                idleAndExit()
                return
            }
        }
    }

    /// §3.6 finishing wait of the new build: past 60 seconds without a
    /// `completeHostUpdate`, drop the marker and resume `normal` work. A
    /// different marker on disk is a newer update's, and is left alone.
    private func expireFinishingMarker(_ marker: HostUpdateMarker) async {
        try? await Task.sleep(for: .seconds(Self.finishingMarkerAge))
        guard readMarker() == marker, case .updating = hostState else { return }
        removeMarker()
        hostState = .normal
        publish(.hostStateChanged(hostState))
    }

    private func readMarker() -> HostUpdateMarker? {
        Self.readMarker(at: markerURL)
    }

    private static func readMarker(at url: URL) -> HostUpdateMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HostUpdateMarker.self, from: data)
    }

    private func writeMarker(_ marker: HostUpdateMarker) throws {
        let data = try JSONEncoder().encode(marker)
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: markerURL, options: .atomic)
    }

    /// The probe snapshot for `selfUpdateStatus` (runtime-api.md §12.2).
    func selfUpdateStatus() -> SelfUpdateStatus {
        selfUpdate
    }

    /// Whether APKRun.app reported a Sparkle result during this daemon run
    /// (§3.4: the probe only notifies while APKRun.app is not connected; a
    /// `--notify` launch never calls `noteSelfUpdateStatus`).
    private(set) var appReportedThisRun = false

    /// Records Sparkle's result from APKRun.app and publishes the change
    /// (runtime-api.md §12.2).
    func noteSelfUpdate(_ note: SelfUpdateNote) {
        appReportedThisRun = true
        selfUpdate = SelfUpdateStatus(
            currentVersion: version,
            currentBuild: build,
            latest: note.found,
            critical: false,
            lastCheckedAt: note.checkedAt,
            lastError: nil,
            pendingOnQuit: note.pendingOnQuit)
        publish(.selfUpdateStatusChanged(selfUpdate))
    }

    /// Merges the probe's own snapshot (§3.4) and publishes the change.
    func updateSelfUpdateStatus(_ status: SelfUpdateStatus) {
        selfUpdate = status
        publish(.selfUpdateStatusChanged(status))
    }

    private func removeMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }
}
