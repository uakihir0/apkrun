import Foundation
import RuntimeAPI

// MARK: - Frozen maintenance endpoint dispatch (runtime-api.md §12)

extension RuntimeHost {
    /// Watches `APKRun.app`'s on-disk build; §3.6. `nil` when apkrund is not
    /// inside a `.app` bundle (development runs).
    var bundleWatcher: BundleWatcher? {
        if let _bundleWatcher { return _bundleWatcher }
        guard let bundleURL = Self.apkRunAppBundleURL() else { return nil }
        let watcher = BundleWatcher(
            bundleURL: bundleURL,
            ownBuild: buildIdentity.buildNumberInt
        ) { [weak self] onDiskBuild in
            Task { await self?.noteBundleReplaced(build: onDiskBuild) }
        }
        _bundleWatcher = watcher
        return watcher
    }

    /// `APKRun.app` that contains this apkrund binary
    /// (`APKRun.app/Contents/Library/LaunchServices/io.apkrun.apkrund`).
    static func apkRunAppBundleURL() -> URL? {
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while url.pathExtension != "app", url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url.pathExtension == "app" ? url : nil
    }

    /// §3.6: re-check the bundle build (called on every broker `hello`).
    func checkBundleForReplacement() {
        bundleWatcher?.check()
    }

    /// Starts the 60 s poll and the vnode watch once the host is up.
    func startBundleWatcher() {
        bundleWatcher?.start()
    }

    /// `BundleWatcher` reports the on-disk build changed (§3.6).
    func noteBundleReplaced(build: Int?) async {
        await maintenanceService.noteBundleReplaced(bundleBuild: build)
        maintenanceHostState = await maintenanceService.state
    }

    /// The maintenance coordinator; built on first use so boot stays cheap.
    var maintenanceService: MaintenanceService {
        if let _maintenanceService { return _maintenanceService }
        let service = MaintenanceService(
            markerFile: paths.maintenanceStateFile,
            version: buildIdentity.marketingVersion,
            build: buildIdentity.buildNumberInt,
            publish: { [eventHub] event in
                eventHub.publishMaintenanceEvent(event)
            },
            sessionsProvider: { [weak self] in
                await self?.maintenanceSessionPackageIDs() ?? []
            },
            backgroundTasksProvider: { [weak self] in
                await self?.maintenanceBackgroundTaskPackageIDs() ?? []
            },
            activitiesProvider: { [updateIdleController] in
                await updateIdleController.activeActivities.map {
                    RuntimeAPI.ActivityKind(rawValue: $0.rawValue)
                }
            },
            imageMigratingProvider: { [weak self] in
                await self?.imageMigrating ?? false
            },
            idleAndExit: { [weak self] in
                Task { await self?.requestRestartExit() }
            }
        )
        _maintenanceService = service
        return service
    }

    /// The self-update probe snapshot (`selfUpdateStatus`, runtime-api.md §12.2).
    func selfUpdateStatus() async -> SelfUpdateStatus {
        await maintenanceService.selfUpdateStatus()
    }

    /// Records Sparkle's result from APKRun.app (`noteSelfUpdateStatus`, §12.2).
    func noteSelfUpdate(_ note: SelfUpdateNote) async {
        await maintenanceService.noteSelfUpdate(note)
    }

    /// Runs one operation from the frozen `.maintenance` endpoint. The
    /// endpoint answers in every host state (§12.1), so there is no
    /// lifecycle or host-state gate here.
    func maintenanceOperation(
        _ request: MaintenanceControlRequest
    ) async -> MaintenanceControlReply {
        switch request.operation {
        case .maintenanceStatus:
            let status = await maintenanceService.status()
            return MaintenanceControlReply(status: status)
        case .prepareForHostUpdate:
            guard let update = request.hostUpdate else {
                return Self.maintenanceErrorReply(
                    "malformedRequest",
                    message: "prepareForHostUpdate requires hostUpdate.")
            }
            do throws(RuntimeWireError) {
                try await maintenanceService.prepareForHostUpdate(update)
            } catch {
                return Self.maintenanceErrorReply(error)
            }
            maintenanceHostState = await maintenanceService.state
        case .abortHostUpdate:
            await maintenanceService.abortHostUpdate()
            maintenanceHostState = await maintenanceService.state
        case .completeHostUpdate:
            await maintenanceService.completeHostUpdate()
            maintenanceHostState = await maintenanceService.state
        case .restartForUpdate:
            do throws(RuntimeWireError) {
                try await maintenanceService.restartForUpdate(
                    request.restart ?? RestartForUpdateRequest(closeSessions: false))
            } catch {
                return Self.maintenanceErrorReply(error)
            }
        @unknown default:
            return Self.maintenanceErrorReply(
                "unknownOperation",
                message: "The maintenance operation is not supported by this build.")
        }
        return MaintenanceControlReply()
    }

    private static func maintenanceErrorReply(
        _ code: String,
        message: String
    ) -> MaintenanceControlReply {
        MaintenanceControlReply(
            error: RuntimeWireError(domain: "maintenance", code: code, message: message))
    }

    private static func maintenanceErrorReply(_ error: RuntimeWireError) -> MaintenanceControlReply {
        MaintenanceControlReply(error: error)
    }

    private func maintenanceSessionPackageIDs() async -> [RuntimePackageID] {
        guard let service = sessionServiceForIntegrations() else { return [] }
        return await service.maintenanceSessionPackageIDs()
    }

    private func maintenanceBackgroundTaskPackageIDs() async -> [RuntimePackageID] {
        guard let service = sessionServiceForIntegrations() else { return [] }
        return await service.maintenanceBackgroundTaskPackageIDs()
    }

    /// Marks the daemon exit-eligible once idle (`restartPending`, §3.7).
    func requestRestartExit() {
        restartExitRequested = true
    }
}

extension RuntimeHost {
    /// The §3.7 gate: `updating` refuses every non-maintenance operation and
    /// `restartPending` refuses Android-starting work and bundle readers.
    /// The maintenance endpoint itself never consults this gate.
    func assertMaintenanceGateAllowsWork() throws(RuntimeWireError) {
        switch maintenanceHostState {
        case .updating:
            throw .runtime(
                "hostUpdating",
                message: "APKRun is updating itself.",
                remediation: "Wait for the update to finish, then try again.")
        case .restartPending:
            throw .runtime(
                "hostUpdating",
                message: "APKRun is restarting to finish an update.",
                remediation: "Wait a moment and try again.")
        case .normal, .unknown:
            return
        }
    }
}
