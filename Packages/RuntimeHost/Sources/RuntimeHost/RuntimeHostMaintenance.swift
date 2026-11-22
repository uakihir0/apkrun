import Foundation
import RuntimeAPI
import UpdateCore

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
        lastOnDiskBundleBuild = build
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
            endSessions: { [weak self] in
                guard let service = await self?.sessionServiceForIntegrations() else { return }
                for packageID in await service.maintenanceSessionPackageIDs() {
                    await service.endSessionForUpdate(packageID: packageID)
                }
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
        apkrunAppReported = true
        await maintenanceService.noteSelfUpdate(note)
    }

    // MARK: - Background probe (runtime-maintenance.md §3.4)

    /// The appcast feed URL: `SUFeedURL` of the containing bundle, or the
    /// test override for development builds without a bundle.
    private var selfUpdateFeedURL: URL? {
        // Test overrides exist in development builds only; a Release build
        // must always read the feed URL and trust key from the bundle (§3.4).
        #if DEBUG
            if let override = ProcessInfo.processInfo.environment["APKRUN_TEST_SELF_UPDATE_FEED_URL"],
                let url = URL(string: override)
            {
                return url
            }
        #endif
        guard let bundle = Self.apkRunAppBundleURL(),
            let raw = Bundle(url: bundle)?.object(forInfoDictionaryKey: "SUFeedURL") as? String
        else { return nil }
        return URL(string: raw)
    }

    /// Reads the app bundle's Sparkle keys (`SURequireSignedFeed`,
    /// `SUPublicEDKey`) for the probe's feed signature check.
    private var selfUpdateBundleInfo: [String: Any] {
        guard let bundle = Self.apkRunAppBundleURL() else { return [:] }
        let info = Bundle(url: bundle)?.infoDictionary ?? [:]
        var out: [String: Any] = [:]
        #if DEBUG
            if let flag = ProcessInfo.processInfo.environment["APKRUN_TEST_SELF_UPDATE_PUBLIC_KEY"] {
                out["SUPublicEDKey"] = flag
                out["SURequireSignedFeed"] = true
                return out
            }
        #endif
        out["SURequireSignedFeed"] = info["SURequireSignedFeed"]
        out["SUPublicEDKey"] = info["SUPublicEDKey"]
        return out
    }

    /// The background appcast probe, created lazily with the daemon's
    /// `state.json` persistence and notification plumbing (§3.4, §9).
    var selfUpdateProbe: SelfUpdateProbe {
        if let _selfUpdateProbe { return _selfUpdateProbe }
        let info = selfUpdateBundleInfo
        let store = provisioningStore
        let state = SelfUpdateProbeState()
        let probe = SelfUpdateProbe(
            feedURL: selfUpdateFeedURL,
            http: URLSessionUpdateHTTPClient(),
            ownVersion: buildIdentity.marketingVersion,
            ownBuild: buildIdentity.buildNumberInt,
            allowedChannels: selfUpdateAllowedChannels(),
            requiresSignedFeed: info["SURequireSignedFeed"] as? Bool ?? false,
            publicEDKey: info["SUPublicEDKey"] as? String,
            state: state,
            persist: { probeState in
                Task {
                    try? await store.update { $0.selfUpdate = probeState }
                }
            },
            notify: { [weak self] release, _ in
                Task { await self?.notifySelfUpdateAvailable(release) }
            },
            appConnected: { [weak self] in
                await self?.apkrunAppReported ?? false
            },
            load: {
                (try? await store.load())?.selfUpdate ?? SelfUpdateProbeState()
            }
        )
        _selfUpdateProbe = probe
        return probe
    }

    /// The probe needs the persisted `selfUpdate` block; loaded asynchronously
    /// the first time `selfUpdateProbe` runs a check.
    private func selfUpdateAllowedChannels() -> Set<String> {
        let channel =
            GlobalSettings.load(from: paths.settingsFile)
            .extraValue("maintenance.channel") ?? "stable"
        return channel == "beta" ? ["beta"] : []
    }

    /// `checkSelfUpdate(userInitiated)` (runtime-api.md §12.2, §3.4).
    func checkSelfUpdate(userInitiated: Bool) async -> SelfUpdateStatus {
        let status = await selfUpdateProbe.check(userInitiated: userInitiated)
        await maintenanceService.updateSelfUpdateStatus(status)
        return status
    }

    /// Posts "APKRun ‹v› is available. Open APKRun to install it." through the
    /// host-notifications stream (§3.4). No-op while no client holds the
    /// stream (APKRun.app is then not connected — the message is recorded via
    /// `notifiedBuilds` so it arrives on the next app launch).
    private func notifySelfUpdateAvailable(_ release: AvailableRelease) {
        _ = streamCenter.sendHostNotification(
            .post(
                HostNotificationPayload(
                    identifier: "self-update-\(release.build)",
                    kind: .selfUpdateAvailable,
                    title: "APKRun \(release.version) is available.",
                    body: WireLocalizedText(
                        key: "maintenance.selfUpdateAvailable",
                        fallback: "Open APKRun to install it."),
                    actions: [.update],
                    targetURL: "apkrun://settings/general"
                )))
    }

    /// Registers `maintenance.selfUpdate` (§12) once at daemon startup.
    func registerSelfUpdateHealthCheck() async {
        guard let registry = healthCheckRegistry else { return }
        try? await registry.register(
            SelfUpdateHealthCheck { [weak self] in
                guard let self else {
                    return SelfUpdateHealthCheck.Snapshot(
                        latest: nil, critical: false, lastCheckedAt: nil,
                        lastError: nil, criticalNotifiedAt: nil,
                        autoCheckEnabled: false, hostState: .unknown,
                        stateSince: nil, hostDowngraded: false,
                        feedConfigured: false)
                }
                let status = await self.selfUpdateProbe.status()
                let state = (try? await self.provisioningStore.load())?.selfUpdate
                let settingsFile = await self.paths.settingsFile
                let autoCheck =
                    GlobalSettings.load(from: settingsFile)
                    .extraValue("maintenance.checkAutomatically") != "false"
                let hostState = await self.maintenanceHostState
                let stateSince = await Date()
                    .timeIntervalSince(self.maintenanceHostStateSince)
                let onDiskBuild = await self.lastOnDiskBundleBuild
                let ownBuild = await self.buildIdentity.buildNumberInt
                let feedConfigured = await self.selfUpdateFeedURL != nil
                return SelfUpdateHealthCheck.Snapshot(
                    latest: status.latest,
                    critical: status.critical,
                    lastCheckedAt: status.lastCheckedAt,
                    lastError: status.lastError,
                    criticalNotifiedAt: state?.criticalNotifiedAt,
                    autoCheckEnabled: autoCheck,
                    hostState: hostState,
                    stateSince: stateSince,
                    hostDowngraded: (onDiskBuild ?? .max) < ownBuild,
                    feedConfigured: feedConfigured)
            })
    }

    /// The §3.4 loop: once per 24 h (± 1 h jitter) while automatic checks are
    /// on. Called once after startup finishes.
    func startSelfUpdateProbeLoop() {
        guard selfUpdateFeedURL != nil, selfUpdateProbeTask == nil else { return }
        selfUpdateProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let enabled =
                    GlobalSettings.load(from: self.paths.settingsFile)
                    .extraValue("maintenance.checkAutomatically") != "false"
                if enabled { _ = await self.checkSelfUpdate(userInitiated: false) }
                let jitter = Duration.seconds(Int64.random(in: -3600...3600))
                try? await Task.sleep(for: .seconds(24 * 3600) + jitter)
            }
        }
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

    func maintenanceSessionPackageIDs() async -> [RuntimePackageID] {
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
