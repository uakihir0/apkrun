import APKStoreCore
import CoreGraphics
import DiagnosticsCore
import Foundation
import IOKit.ps
import Network
import RuntimeAPI
import RuntimeCore
import UpdateCore

/// The daemon's update service (update-system.md). It owns the `Updates/`
/// state and history stores, the provider `UpdateCoordinator`, and a host-side
/// `PackageStore` for records and settings. It never starts Android; update
/// work only reads provider metadata and stages artifacts on disk.
public actor EmbeddedUpdateService {
    private let paths: APKRunPaths
    private let fileManager = FileManager.default
    let store: PackageStore
    /// The persisted update phases; internal for the `updates.waiting`
    /// health check and tests.
    let stateStore: UpdateStateStore
    /// Internal for the §3 scheduler the host drives.
    let coordinator: UpdateCoordinator
    private let credentials = KeychainProviderCredentials()
    private var isOpen = false

    /// Creates an update service rooted at APKRun's data directory.
    ///
    /// `store` should be the `PackageStore` shared with the package service:
    /// a second store on the same directory would delete another service's
    /// pending import tickets during `open()` cleanup. `notifier` receives
    /// `notifyOnly` update notifications; without one the notification stays
    /// pending instead of being marked delivered.
    public init(
        paths: APKRunPaths = APKRunPaths(allowingHomeOverride: true),
        store: PackageStore? = nil,
        developerModeEnabled: @escaping @Sendable () -> Bool = { false },
        checkIntervalHours: @escaping @Sendable () -> Int = { 6 },
        guestFacts: @escaping @Sendable () -> GuestFacts = { GuestFacts() },
        notifier: (any HostNotificationSink)? = nil
    ) {
        self.paths = paths
        self.store =
            store
            ?? PackageStore(
                packagesDirectory: paths.packagesDirectory,
                inspector: { apk in try await APKInspector().inspect(apk) },
                fileManager: .default
            )
        stateStore = UpdateStateStore(directory: paths.updatesDirectory)
        coordinator = UpdateCoordinator(
            store: self.store,
            stateStore: stateStore,
            notifier: notifier,
            developerModeEnabled: developerModeEnabled,
            checkIntervalHours: checkIntervalHours(),
            guestFacts: guestFacts,
            installedNotificationEnabled: {
                GlobalSettings.load(
                    from: APKRunPaths(allowingHomeOverride: true).settingsFile
                ).updatesNotifyInstalled
            }
        )
    }

    /// Opens the package store; safe to call on every request.
    public func open() async throws {
        guard !isOpen else { return }
        try await store.open()
        isOpen = true
    }

    /// The provider context for a check (update-system.md §4.1).
    public func providerContext(userInitiated: Bool) -> ProviderContext {
        ProviderContext(
            http: URLSessionUpdateHTTPClient(),
            cache: FileProviderCache(root: paths.updatesDirectory.appendingPathComponent("cache", isDirectory: true)),
            credentials: credentials,
            userInitiated: userInitiated
        )
    }

    /// Runs a check for every package ID (update-system.md §5). The outcome is
    /// per package; a failing package never fails the batch. With
    /// `checkOnly == false` a package whose choice is `automatic` continues
    /// past `available` into download, validation, and install (runtime-api.md
    /// §9.2); `notifyOnly` and `manual` stop at `available`.
    public func checkPackages(
        _ packageIDs: [PackageID],
        context: ProviderContext,
        checkOnly: Bool = false,
        runtime: (any UpdateRuntimeAccess)? = nil,
        gate: GentleUpdateGate? = nil
    ) async -> [UpdateCheckResult] {
        var results: [UpdateCheckResult] = []
        let records = (try? await store.listManagedPackages()) ?? []
        for packageID in packageIDs {
            let outcome = await coordinator.check(
                packageID, trigger: .userInitiated, context: context,
                checkOnly: checkOnly)
            guard let wireID = RuntimePackageID(rawValue: packageID.rawValue) else { continue }
            switch outcome {
            case .upToDate:
                results.append(UpdateCheckResult(packageID: wireID, outcome: .upToDate))
            case .available(let candidate):
                let record = records.first(where: { $0.packageId == packageID })
                let settings = try? await store.packageSettings(for: packageID)
                let choice = record.map {
                    Self.choice(authority: $0.updateAuthority, mode: settings?.updateMode)
                }
                guard !checkOnly, choice == .automatic, let runtime else {
                    results.append(
                        UpdateCheckResult(
                            packageID: wireID, outcome: .available(Self.wireCandidate(candidate))))
                    break
                }
                let updateOutcome = await continueUpdate(
                    packageID, candidate: candidate, trigger: .userInitiated,
                    context: context, runtime: runtime, gate: gate, started: Date())
                results.append(
                    UpdateCheckResult(
                        packageID: wireID,
                        outcome: await Self.checkResultOutcome(
                            updateOutcome,
                            blocks: gate?.waitingReasons(packageID) ?? [])))
            case .failed(let failure):
                results.append(
                    UpdateCheckResult(
                        packageID: wireID,
                        outcome: .failed(Self.catalogError(for: failure))))
            }
        }
        return results
    }

    /// Runs download → validate → install after a check surfaced a candidate
    /// (update-system.md §5–§8). A nil result means the update is staged and
    /// waits for the gate to open (§7.3).
    func continueUpdate(
        _ packageID: PackageID,
        candidate: UpdateCandidate,
        trigger: UpdateTrigger,
        context: ProviderContext,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate? = nil,
        started: Date,
        origin: ArtifactOrigin? = nil,
        closeRunningApp: Bool = false
    ) async -> WireUpdateOutcome? {
        switch await coordinator.download(
            packageID, candidate: candidate, context: context,
            trigger: trigger, started: started)
        {
        case .downloaded(let downloaded):
            return await validateAndInstall(
                packageID, ticket: downloaded.ticket, candidate: candidate,
                trigger: trigger, runtime: runtime, gate: gate, started: started,
                origin: origin, closeRunningApp: closeRunningApp)
        case .failed(let failure):
            return .skipped(reason: "downloadFailed", error: Self.catalogError(for: failure))
        }
    }

    /// Runs validate → install on an already-downloaded ticket. `origin`
    /// overrides the provider-derived origin (manual file updates).
    func validateAndInstall(
        _ packageID: PackageID,
        ticket: UUID,
        candidate: UpdateCandidate,
        trigger: UpdateTrigger,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate? = nil,
        started: Date,
        origin: ArtifactOrigin? = nil,
        closeRunningApp: Bool = false
    ) async -> WireUpdateOutcome? {
        // A manual file update or an explicit `update --from` counts as the
        // user selecting the version (V6, update-system.md §6).
        let explicitSelection =
            origin?.type == .manualFile || trigger == .manual
        switch await coordinator.validate(
            packageID, ticket: ticket, candidate: candidate,
            trigger: trigger, started: started,
            explicitSelection: explicitSelection)
        {
        case .validated(let validated):
            switch await coordinator.install(
                packageID, validated: validated, candidate: candidate,
                trigger: trigger, runtime: runtime,
                gate: gate ?? gateInstance(runtime: runtime), started: started,
                origin: origin, closeRunningApp: closeRunningApp)
            {
            case .installed(let from, let to):
                return .updated(from: from, to: to)
            case .rolledBack(let failure):
                return .rolledBack(reason: failure.errorCode)
            case .keptAfterFailedHealthCheck(let failure):
                return .keptAfterFailedHealthCheck(reason: failure.errorCode)
            case .staged:
                return nil
            case .failed(let failure):
                return .skipped(reason: "installFailed", error: Self.catalogError(for: failure))
            }
        case .failed(let failure):
            return .skipped(reason: "validationFailed", error: Self.catalogError(for: failure))
        }
    }

    /// The gate installs share; a caller-supplied gate wins so the host's
    /// trigger pump sees the same queue.
    private var serviceGate: GentleUpdateGate?
    func gateInstance(runtime: any UpdateRuntimeAccess) -> GentleUpdateGate {
        if let serviceGate { return serviceGate }
        let gate = GentleUpdateGate(
            runtime: runtime,
            storeBusy: { [store] packageID in
                await store.packageMutationInProgress(packageID)
            },
            // §8.2: the health launch reuses the session's display lease; a
            // pool with no free scanout answers `.launchFailed` rather than
            // blocking the install queue on a display slot.
            requiresDisplaySlot: { _ in false },
            displaySlotFree: { true })
        serviceGate = gate
        return gate
    }

    /// §7.2: a session's first frame counted as the install's H4 — the
    /// session waited on the committing install, then launched the new
    /// version itself.
    func notePostUpdateFirstFrame(_ packageID: PackageID) async {
        await stateStore.update(packageID) { $0.postUpdateFirstFrameAt = Date() }
    }

    /// §7.4: notifies once per staged candidate waiting over 7 days.
    func notifyOverdueStagedUpdates(now: Date = Date()) async {
        await coordinator.notifyOverdueStagedUpdates(now: now)
    }

    /// §7.2 trigger: runs the staged install the gate pump admitted.
    func resumeStagedInstall(
        _ packageID: PackageID,
        trigger: UpdateTrigger = .scheduled,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate
    ) async -> UpdateCoordinator.UpdateInstallOutcome? {
        await coordinator.resumeStagedInstall(
            packageID, trigger: trigger, runtime: runtime, gate: gate)
    }

    /// The §7.1 block as the wire waiting reason (runtime-api.md
    /// `WaitingReason`).
    static func waitingReason(for block: GentleGateBlock?) -> WaitingReason {
        switch block {
        case .runtimeNotReady:
            .runtimeNotReady
        case .packageInUse, nil:
            .appInUse
        case .sessionEndedRecently, .androidBusy, .storeTransactionActive, .noDisplaySlot:
            .conditionsUnmet
        }
    }

    /// Maps a continued update's wire outcome onto `UpdateCheckResult.Result`
    /// (runtime-api.md §9.2): nil (still waiting) reports `.waiting` with the
    /// §7.1 blocks the gate last evaluated.
    static func checkResultOutcome(
        _ outcome: WireUpdateOutcome?,
        blocks: [GentleGateBlock]
    ) -> UpdateCheckResult.Result {
        switch outcome {
        case nil:
            return .waiting(Self.waitingReason(for: blocks.first))
        case .updated(let from, let to):
            return .installed(from: from, to: to)
        case .keptAfterFailedHealthCheck(let reason):
            return .failed(WireError(domain: "update", code: reason))
        case .skipped(_, let error):
            return .failed(error ?? WireError(domain: "update", code: "unknown"))
        case .rolledBack(let reason):
            return .failed(WireError(domain: "update", code: reason))
        }
    }

    /// `updatePackage` without files: check now, then install when the check
    /// surfaces a candidate regardless of update choice (§7.3).
    public func updatePackageNow(
        _ packageID: PackageID,
        context: ProviderContext,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate? = nil,
        closeRunningApp: Bool = false
    ) async -> WireUpdateOutcome? {
        let started = Date()
        switch await coordinator.check(
            packageID, trigger: .userInitiated, context: context,
            checkOnly: false)
        {
        case .upToDate:
            return .skipped(reason: "upToDate", error: nil)
        case .available(let candidate):
            return await continueUpdate(
                packageID, candidate: candidate, trigger: .userInitiated,
                context: context, runtime: runtime, gate: gate, started: started,
                closeRunningApp: closeRunningApp)
        case .failed(let failure):
            return .skipped(reason: "checkFailed", error: Self.catalogError(for: failure))
        }
    }

    /// `updatePackage` with files: the imported ticket enters the pipeline at
    /// `validating` with trigger `manual` (update-system.md §7.1).
    public func updateFromFile(
        _ packageID: PackageID,
        ticket: UUID,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate? = nil,
        closeRunningApp: Bool = false
    ) async throws(RuntimeWireError) -> WireUpdateOutcome? {
        let started = Date()
        let records = (try? await store.listManagedPackages()) ?? []
        guard let record = records.first(where: { $0.packageId == packageID }) else {
            throw .store(
                "packageNotFound",
                message: "The package is not managed by APKRun.",
                remediation: "Install the app first with `apkrun install`.")
        }
        switch record.updateAuthority {
        case .googlePlay, .external:
            return .skipped(
                reason: "checkFailed",
                error: Self.catalogError(for: UpdateFailure.authorityDoesNotAllowUpdates))
        case .apkrun, .manual:
            break
        }
        let candidate = UpdateCandidate(
            packageID: packageID,
            provider: UpdateProviderRef(
                type: .local, configuration: .local(path: "file", bookmark: "")),
            artifacts: [],
            cursor: ProviderCursor(type: .local, value: ticket.uuidString))
        return await validateAndInstall(
            packageID, ticket: ticket, candidate: candidate,
            trigger: .manual, runtime: runtime, gate: gate, started: started,
            origin: ArtifactOrigin(type: .manualFile),
            closeRunningApp: closeRunningApp)
    }

    /// Every managed package whose record authority is `apkrun`.
    public func managedPackageIDs() async throws -> [PackageRecord] {
        try await store.listManagedPackages()
    }

    /// `listUpdates`: the per-package status rows of runtime-api.md §9.2.
    public func listUpdates() async throws -> [PackageUpdateStatus] {
        let records = try await store.listManagedPackages()
        var statuses: [PackageUpdateStatus] = []
        for record in records {
            statuses.append(try await status(for: record))
        }
        return statuses
    }

    /// One package's status.
    public func status(for record: PackageRecord) async throws -> PackageUpdateStatus {
        let state = await stateStore.state(for: record.packageId)
        let phase = await coordinator.phase(for: record.packageId)
        let settings = try? await store.packageSettings(for: record.packageId)
        guard let wireID = RuntimePackageID(rawValue: record.packageId.rawValue) else {
            throw UpdateFailure.validation(detail: "stored package id is not a wire id")
        }
        return PackageUpdateStatus(
            packageID: wireID,
            choice: Self.choice(authority: record.updateAuthority, mode: settings?.updateMode),
            authority: record.updateAuthority.rawValue,
            provider: record.updateProvider.map { Self.providerSummary($0, credentials: credentials) },
            phase: phase.map(Self.wirePhase),
            candidate: state?.candidate.map {
                WireUpdateCandidate(
                    versionCode: $0.versionCode,
                    versionName: $0.versionName,
                    provider: $0.provider.rawValue)
            },
            lastCheckAt: state?.lastCheckAt,
            nextCheckAt: state?.nextCheckAt,
            consecutiveFailures: state?.consecutiveFailures ?? 0,
            waiting: []
        )
    }

    /// `updateHistory` (update-system.md §10.2).
    public func updateHistory(
        packageID: PackageID?,
        limit: Int
    ) async throws -> [RuntimeAPI.UpdateHistoryEntry] {
        try await stateStore.history(packageID: packageID, limit: limit).map {
            guard let wireID = RuntimePackageID(rawValue: $0.packageID.rawValue) else {
                throw UpdateFailure.validation(detail: "stored package id is not a wire id")
            }
            return RuntimeAPI.UpdateHistoryEntry(
                time: $0.time,
                packageID: wireID,
                from: $0.from,
                to: $0.to,
                provider: $0.provider?.rawValue,
                trigger: $0.trigger.rawValue,
                outcome: $0.outcome,
                failure: nil,
                phaseDurationsMs: $0.phaseDurationsMs
            )
        }
    }

    /// `setUpdatePolicy` (update-system.md §2.3, cli.md §4.3): the settings
    /// `update.mode` is written before `metadata.json` so a crash never turns
    /// automatic updates on without the record change.
    public func setUpdatePolicy(
        packageID: PackageID,
        policy: UpdatePolicy
    ) async throws -> PackageRecord {
        guard
            let record = try await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            throw PackageStoreFailure.packageNotFound
        }
        // The §2.1–§2.4 authority rules live in UpdateCore.
        let resolution = try UpdatePolicyRules.resolve(policy, for: record)

        try await store.setUpdateMode(for: packageID, mode: resolution.settingsMode)
        // `requireProvider` makes the provider requirement atomic inside the
        // store's mutation lock; the pre-check in resolve cannot see a
        // concurrent removal.
        try await store.setUpdatePolicy(
            for: packageID, authority: resolution.authority,
            provider: resolution.provider, removeProvider: resolution.removeProvider,
            requireProvider: resolution.requireProvider)
        guard
            let updated = try await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            throw PackageStoreFailure.packageNotFound
        }
        return updated
    }

    /// `setUpdateAuthority` (update-system.md §2.1, §11.1, cli.md §4.3).
    /// `googlePlay` is not user-settable (#98 only) and a `googlePlay` record
    /// refuses every change. Moving to `external` relinquishes update
    /// ownership before the record write (PackageStore, package-store.md §6.3);
    /// a staged set the new authority does not install is discarded.
    public func setUpdateAuthority(
        packageID: PackageID,
        authority: AuthorityChoice
    ) async throws -> PackageRecord {
        guard authority != .googlePlay else {
            throw UpdateFailure.authorityDoesNotAllowUpdates
        }
        guard
            let record = try await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            throw PackageStoreFailure.packageNotFound
        }
        if record.updateAuthority == .googlePlay {
            throw UpdateFailure.authorityDoesNotAllowUpdates
        }
        let target: UpdateAuthority
        switch authority {
        case .apkrun:
            guard record.updateProvider != nil else {
                throw UpdateFailure.providerNotConfigured
            }
            target = .apkrun
        case .manual: target = .manual
        case .external: target = .external
        case .googlePlay: target = .googlePlay
        }
        // Provider-staged sets die with the authority that can no longer
        // install them: leaving apkrun, and every move to external (§2.1).
        // A manual-file staged set survives a move to `manual` — installing
        // it is exactly what the manual authority does.
        let stagedSurvives =
            target == .manual && record.artifacts.staged?.origin.type == .manualFile
        if record.updateAuthority != target,
            record.updateAuthority == .apkrun || target == .external,
            !stagedSurvives
        {
            try await store.discardStaged(packageID: packageID)
        }
        try await store.setUpdateAuthority(id: packageID, authority: target)
        guard
            let updated = try await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            throw PackageStoreFailure.packageNotFound
        }
        return updated
    }

    /// §8.5: rolls the package back to `previous/`. The coordinator
    /// decides which §7.3 mechanism can run.
    public func rollbackPackage(
        packageID: PackageID,
        allowDataLoss: Bool = false
    ) async throws -> UpdateCoordinator.UpdateRollbackOutcome {
        try await coordinator.rollbackPackage(packageID, allowDataLoss: allowDataLoss)
    }

    /// §8.4: adds (`skipped` true) or removes a version on the skip list.
    /// Skipping discards any staged set (update-system.md §8.4).
    public func setSkippedVersion(
        packageID: PackageID,
        versionCode: VersionCode,
        skipped: Bool
    ) async throws {
        if skipped {
            try await store.discardStaged(packageID: packageID)
            await stateStore.skipVersion(packageID, versionCode: versionCode)
        } else {
            await stateStore.unskipVersion(packageID, versionCode: versionCode)
        }
    }

    /// The wire `UpdateChoice` a record and its settings mode describe. The
    /// rule lives in UpdateCore (update-system.md §2.2).
    static func choice(authority: UpdateAuthority, mode: String?) -> UpdateChoice? {
        UpdatePolicyRules.choice(authority: authority, mode: mode)
    }

    /// The `ProviderSummary` a stored reference produces; never carries a token.
    static func providerSummary(
        _ ref: UpdateProviderRef,
        credentials: any ProviderCredentials
    ) -> ProviderSummary {
        switch ref.configuration {
        case .local(let path, _):
            return ProviderSummary(type: ref.type.rawValue, label: path)
        case .direct(let url):
            return ProviderSummary(type: ref.type.rawValue, label: url)
        case .fdroid(let repository, _):
            return ProviderSummary(type: ref.type.rawValue, label: repository)
        case .github(let repository, _, let channel):
            return ProviderSummary(
                type: ref.type.rawValue,
                label: repository,
                channel: channel.rawValue,
                hasToken: credentials.token(for: "io.apkrun.provider.github") != nil)
        }
    }

    /// The wire phase an internal phase maps to; unknown phases stay unknown.
    static func wirePhase(_ phase: UpdatePhase) -> WireUpdatePhase {
        switch phase {
        case .checking: .checking
        case .available(let candidate): .available(wireCandidate(candidate))
        case .downloading(let progress): .downloading(progress: progress)
        case .validating: .validating
        case .staged: .staged
        case .installing: .installing
        case .healthChecking: .healthChecking
        case .rollingBack(let reason):
            .rollingBack(reason: String(describing: reason))
        case .completed(let outcome): .completed(wireOutcome(outcome))
        }
    }

    /// The wire outcome of a completed run (state-machines.md §6).
    static func wireOutcome(_ outcome: UpdateOutcome) -> WireUpdateOutcome {
        switch outcome {
        case .updated(let from, let to):
            .updated(from: from, to: to)
        case .rolledBack(let reason):
            .rolledBack(reason: String(describing: reason))
        case .keptAfterFailedHealthCheck(let reason):
            .keptAfterFailedHealthCheck(reason: String(describing: reason))
        case .skipped(let reason):
            .skipped(reason: reason.name, error: nil)  // SkipReason.name is UpdateCore-internal
        }
    }

    /// The wire candidate of a provider candidate (runtime-api.md §9.2).
    static func wireCandidate(_ candidate: UpdateCandidate) -> WireUpdateCandidate {
        WireUpdateCandidate(
            versionCode: candidate.declaredVersionCode,
            versionName: candidate.declaredVersionName,
            provider: candidate.provider.type.rawValue,
            releaseNotes: candidate.releaseNotes,
            publishedAt: candidate.publishedAt,
            downloadBytes: candidate.artifacts.reduce(into: Int64(0)) { total, artifact in
                if let size = artifact.size { total += size }
            })
    }

    /// A catalog error for `UpdateCheckResult.failed` (runtime-api.md §9.2);
    /// the message comes from the catalog.
    static func catalogError(for error: any Error) -> WireError {
        let wireError = Self.wireError(for: error)
        return WireError(domain: wireError.domain, code: wireError.code)
    }

    /// A wire error of an update or store failure (runtime-api.md §9.3).
    static func wireError(for error: any Error) -> RuntimeWireError {
        if let wireError = error as? RuntimeWireError {
            return wireError
        }
        if let failure = error as? UpdateFailure {
            return RuntimeWireError(
                domain: "update",
                code: failure.errorCode,
                message: Self.message(for: failure))
        }
        return EmbeddedPackageService.wireError(for: error)
    }

    /// A user-facing message per failure code.
    private static func message(for failure: UpdateFailure) -> String {
        switch failure {
        case .providerUnreachable(let reason):
            "The update provider cannot be reached: \(reason)."
        case .providerHTTPStatus(let status):
            "The update provider answered HTTP \(status)."
        case .providerRateLimited:
            "The update provider is rate-limiting requests."
        case .providerMetadataInvalid(let detail):
            "The update provider metadata is invalid: \(detail)."
        case .providerSignatureInvalid(let detail):
            "The update signature check failed: \(detail)."
        case .noCompatibleArtifact(let reason):
            "The update provider has no compatible artifact (\(reason.rawValue))."
        case .ambiguousAsset(let detail):
            "The update provider offers more than one matching asset: \(detail)."
        case .providerNotConfigured:
            "No update provider is configured for this package."
        case .downloadFailed(let reason):
            "The update download failed: \(reason)."
        case .hashMismatch(let artifact):
            "The downloaded artifact \(artifact) does not match its declared hash."
        case .tooLarge(let bytes, let limit):
            "The update is \(bytes) bytes, above the \(limit)-byte limit."
        case .validation(let detail):
            "The update did not pass validation: \(detail)."
        case .authorityDoesNotAllowUpdates:
            "This package's update authority does not allow APKRun updates."
        case .installFailed(let detail):
            "The update install failed: \(detail)."
        case .healthCheckFailed(let detail):
            "The updated app failed its health check: \(detail)."
        case .rollbackFailed(let detail):
            "The update rollback failed: \(detail)."
        case .cancelled:
            "The update was cancelled."
        }
    }
}

/// The on-disk provider cache under `Updates/cache/<key>/` (§4.1).
public struct FileProviderCache: ProviderCache {
    /// The cache root.
    public let root: URL

    /// Creates a cache rooted at `root`.
    public init(root: URL) {
        self.root = root
    }

    /// Returns the cache directory for `key`, creating it when needed.
    public func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// Keychain storage for provider tokens (update-system.md §4.6). Tokens are
/// generic-password items with `kSecAttrService` naming the provider service.
public struct KeychainProviderCredentials: ProviderCredentials {
    /// Creates the Keychain accessor.
    public init() {}

    /// Returns the stored token for a service name, when one exists.
    public func token(for service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores, replaces (`""` deletes), or keeps (`nil`) a token.
    public func setToken(_ token: String?, for service: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "token",
        ]
        guard let token else { return }
        if token.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(token.utf8)
        if self.token(for: service) != nil {
            SecItemUpdate(
                base as CFDictionary,
                [kSecValueData as String: data] as CFDictionary)
        } else {
            var item = base
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

extension RuntimeHost {
    /// The lazily created update service (update-system.md).
    func updateServiceInstance() -> EmbeddedUpdateService {
        if let updateService { return updateService }
        // Share the package service's store: a second PackageStore over the
        // same directory would treat a pending install's `incoming/` as
        // orphaned scratch and delete it during open() cleanup.
        let service = EmbeddedUpdateService(
            paths: paths,
            store: packageQueryServiceInstance().store,
            developerModeEnabled: { [weak self] in
                guard let self else { return false }
                return GlobalSettings.load(from: self.paths.settingsFile).developerEnabled
            },
            checkIntervalHours: {
                Self.updatesCheckIntervalHours()
            }
        )
        updateService = service
        registerUpdatesWaitingCheck(service: service)
        return service
    }

    /// `apkrun config get` (configuration.md §2.7): the `updates.*` values;
    /// `keys` nil returns all four.
    func updateConfigValues(keys: [String]?) -> [String: String] {
        let globals = GlobalSettings.load(from: paths.settingsFile)
        let all: [String: String] = [
            "updates.checkIntervalHours": String(globals.updatesCheckIntervalHours),
            "updates.downloadOnExpensiveNetwork":
                globals.updatesDownloadOnExpensiveNetwork ? "true" : "false",
            "updates.startRuntimeToInstall":
                globals.updatesStartRuntimeToInstall ? "true" : "false",
            "updates.notifyInstalled": globals.updatesNotifyInstalled ? "true" : "false",
        ]
        guard let keys else { return all }
        return all.filter { keys.contains($0.key) }
    }

    /// `apkrun config set` (configuration.md §2.7): validates and writes one
    /// `updates.*` key, returning the values after the write.
    func updateConfigSet(key: String, value: String) throws -> [String: String] {
        var globals = GlobalSettings.load(from: paths.settingsFile)
        switch key {
        case "updates.checkIntervalHours":
            guard let hours = Int(value),
                GlobalSettings.allowedCheckIntervalHours.contains(hours)
            else {
                throw RuntimeWireError(
                    domain: "runtime", code: "runtime.invalidConfigValue",
                    message:
                        "updates.checkIntervalHours must be one of 1, 3, 6, 12, 24, 72, 168"
                )
            }
            globals.updatesCheckIntervalHours = hours
        case "updates.downloadOnExpensiveNetwork", "updates.startRuntimeToInstall",
            "updates.notifyInstalled":
            guard let flag = value == "true" ? true : value == "false" ? false : nil
            else {
                throw RuntimeWireError(
                    domain: "runtime", code: "runtime.invalidConfigValue",
                    message: "\(key) must be true or false")
            }
            switch key {
            case "updates.downloadOnExpensiveNetwork":
                globals.updatesDownloadOnExpensiveNetwork = flag
            case "updates.startRuntimeToInstall":
                globals.updatesStartRuntimeToInstall = flag
            default:
                globals.updatesNotifyInstalled = flag
            }
        default:
            throw RuntimeWireError(
                domain: "runtime", code: "runtime.unknownConfigKey",
                message: "unknown setting \(key); run `apkrun config get` to list the keys")
        }
        try GlobalSettings.store(globals, to: paths.settingsFile)
        return updateConfigValues(keys: nil)
    }

    /// The lazily created §3 update scheduler: drives due checks, timers,
    /// wake and launch triggers, and the §3.4 resource limits.
    func updateSchedulerInstance() -> UpdateScheduler {
        if let updateScheduler { return updateScheduler }
        let service = updateServiceInstance()
        let scheduler = UpdateScheduler(
            coordinator: service.coordinator,
            stateStore: service.stateStore,
            store: service.store,
            contextProvider: { await service.providerContext(userInitiated: false) },
            runtimeProvider: { [weak self] in await self?.updateRuntimeAccess() },
            gateProvider: { [weak self] in await self?.updateGate },
            networkSatisfied: { Self.updateNetworkPathSatisfied() },
            backgroundDownloadAllowed: {
                Self.updateBackgroundDownloadAllowed()
            })
        updateScheduler = scheduler
        return scheduler
    }

    /// `NWPathMonitor`-backed answer for "may a check run now" (§3.4). The
    /// monitor is created lazily; before its first sample lands the path is
    /// treated as satisfied (a check is cheap, a false negative is not).
    private static let updatePathMonitor = UpdatePathMonitor()
    static func updateNetworkPathSatisfied() -> Bool {
        updatePathMonitor.satisfied
    }

    /// §3.4: a background download needs a non-expensive/non-constrained
    /// path unless `updates.downloadOnExpensiveNetwork`, and is skipped in
    /// Low Power Mode when the staged set tops 50 MiB (approximated here by
    /// "any background download" — the per-set size check lives in the
    /// download step itself).
    static func updateBackgroundDownloadAllowed() -> Bool {
        let globals = GlobalSettings.load(
            from: APKRunPaths(allowingHomeOverride: true).settingsFile)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return false
        }
        return updatePathMonitor.inexpensive
            || globals.updatesDownloadOnExpensiveNetwork
    }

    /// Registers `updates.waiting` once (diagnostics.md §7.4).
    private func registerUpdatesWaitingCheck(service: EmbeddedUpdateService) {
        guard !updatesHealthChecksRegistered, let checks = healthCheckRegistry else { return }
        updatesHealthChecksRegistered = true
        Task {
            try? await checks.register(UpdatesWaitingCheck(stateStore: service.stateStore))
        }
    }

    /// `updates.checkIntervalHours` (configuration.md §2.7), default 6.
    static func updatesCheckIntervalHours() -> Int {
        GlobalSettings.load(
            from: APKRunPaths(allowingHomeOverride: true).settingsFile
        ).updatesCheckIntervalHours
    }

    /// `checkForUpdates` (runtime-api.md §9.1): a long operation that checks
    /// each selected package and reports per-package results.
    public func checkForUpdates(
        packages requestedIDs: [RuntimePackageID]?,
        checkOnly: Bool,
        operationID: RuntimeAPI.OperationID,
        requestPayload: Data,
        clientKind: RuntimeClientKind
    ) async throws(RuntimeWireError) -> (OperationHandle, [UpdateCheckResult]) {
        let service = updateServiceInstance()
        do {
            try await service.open()
        } catch {
            throw EmbeddedPackageService.wireError(for: error)
        }

        let records: [PackageRecord]
        do {
            records = try await service.managedPackageIDs()
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
        var selected: [PackageID] = []
        var preResults: [UpdateCheckResult] = []
        if let requestedIDs {
            for wireID in requestedIDs {
                guard let packageID = PackageID(rawValue: wireID.rawValue),
                    records.contains(where: { $0.packageId == packageID })
                else {
                    preResults.append(
                        UpdateCheckResult(
                            packageID: wireID,
                            outcome: .failed(
                                WireError(domain: "store", code: "store.packageNotFound"))))
                    continue
                }
                selected.append(packageID)
            }
        } else {
            selected = records.filter { $0.updateAuthority == .apkrun }.map(\.packageId)
        }

        let handle = OperationHandle(operationID: operationID, kind: .updateCheck)
        let snapshot = OperationSnapshot(
            operationID: operationID,
            kind: .updateCheck,
            packageID: selected.first.flatMap { RuntimePackageID(rawValue: $0.rawValue) },
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(stage: "checking", message: "Checking for updates…")
        )
        trackedOperations[operationID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            snapshot: snapshot,
            isCancellable: false,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: operationID)

        // A non-checkOnly run can install: hold the package-mutation guard so
        // stop/restart/reset cannot interrupt a stage→install transaction.
        if !checkOnly {
            do {
                try beginPackageMutation()
            } catch {
                finishOperation(
                    operationID, result: .failed(Self.sessionWireError(for: error)))
                throw Self.sessionWireError(for: error)
            }
        }
        defer { if !checkOnly { finishPackageMutation() } }

        let results = await service.checkPackages(
            selected, context: service.providerContext(userInitiated: true),
            checkOnly: checkOnly, runtime: updateRuntimeAccess(),
            gate: updateGateInstance())
        let all = preResults + results
        let failures = all.filter { result in
            if case .failed = result.outcome { return true }
            return false
        }
        if failures.count == all.count, !all.isEmpty {
            // Every check failed: the operation still completed; per-package
            // failures are reported in results (cli.md §4.3).
        }
        finishOperation(operationID, result: .succeeded(.none))
        return (handle, all)
    }

    /// `listUpdates` (runtime-api.md §9.1).
    public func listUpdates() async throws(RuntimeWireError) -> [PackageUpdateStatus] {
        let service = updateServiceInstance()
        do {
            try await service.open()
            return try await service.listUpdates()
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }

    /// `updateHistory` (runtime-api.md §9.1).
    public func updateHistory(
        packageID wireID: RuntimePackageID?,
        limit: Int
    ) async throws(RuntimeWireError) -> [RuntimeAPI.UpdateHistoryEntry] {
        let service = updateServiceInstance()
        do {
            try await service.open()
            let packageID = wireID.flatMap { PackageID(rawValue: $0.rawValue) }
            if let wireID, packageID == nil {
                throw RuntimeWireError.store(
                    "packageNotFound",
                    message: "The package is not managed by APKRun.",
                    remediation: "Use `apkrun list` to see managed packages.")
            }
            return try await service.updateHistory(packageID: packageID, limit: limit)
        } catch let wireError as RuntimeWireError {
            throw wireError
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }

    /// `setUpdatePolicy` (runtime-api.md §9.1, cli.md §4.3).
    public func setUpdatePolicy(
        packageID wireID: RuntimePackageID,
        policy: UpdatePolicy
    ) async throws(RuntimeWireError) -> PackageUpdateStatus {
        let service = updateServiceInstance()
        do {
            try await service.open()
        } catch {
            throw EmbeddedPackageService.wireError(for: error)
        }
        guard let packageID = PackageID(rawValue: wireID.rawValue) else {
            throw .store(
                "packageNotFound",
                message: "The package is not managed by APKRun.",
                remediation: "Use `apkrun list` to see managed packages.")
        }
        do {
            let record = try await service.setUpdatePolicy(packageID: packageID, policy: policy)
            return try await service.status(for: record)
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }

    /// `setUpdateAuthority` (runtime-api.md §9.1, cli.md §4.3).
    public func setUpdateAuthority(
        packageID wireID: RuntimePackageID,
        authority: AuthorityChoice
    ) async throws(RuntimeWireError) -> PackageUpdateStatus {
        let service = updateServiceInstance()
        do {
            try await service.open()
        } catch {
            throw EmbeddedPackageService.wireError(for: error)
        }
        guard let packageID = PackageID(rawValue: wireID.rawValue) else {
            throw .store(
                "packageNotFound",
                message: "The package is not managed by APKRun.",
                remediation: "Use `apkrun list` to see managed packages.")
        }
        do {
            let record = try await service.setUpdateAuthority(
                packageID: packageID, authority: authority)
            return try await service.status(for: record)
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }

    /// `rollbackPackage` (update-system.md §8.5, cli.md §4.3).
    public func rollbackPackage(
        packageID wireID: RuntimePackageID,
        allowDataLoss: Bool
    ) async throws(RuntimeWireError) -> RuntimeRollbackPackageControlReply {
        let service = updateServiceInstance()
        do {
            try await service.open()
        } catch {
            throw EmbeddedPackageService.wireError(for: error)
        }
        guard let packageID = PackageID(rawValue: wireID.rawValue) else {
            throw .store(
                "packageNotFound",
                message: "The package is not managed by APKRun.",
                remediation: "Use `apkrun list` to see managed packages.")
        }
        // A rollback is a package mutation: it blocks stop/restart/reset
        // like installs and uninstalls do (update-system.md §8.5).
        do {
            try beginPackageMutation()
        } catch {
            throw Self.sessionWireError(for: error)
        }
        defer { finishPackageMutation() }
        do {
            switch try await service.rollbackPackage(
                packageID: packageID, allowDataLoss: allowDataLoss)
            {
            case .rolledBack(let to):
                return RuntimeRollbackPackageControlReply(rolledBackTo: to)
            case .unavailable:
                return RuntimeRollbackPackageControlReply(unavailable: true)
            case .failed(let failure):
                throw EmbeddedUpdateService.wireError(for: failure)
            }
        } catch let error as RuntimeWireError {
            throw error
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }

    /// `updateSkipped` (update-system.md §8.4, cli.md §4.3).
    public func setSkippedVersion(
        packageID wireID: RuntimePackageID,
        versionCode: RuntimeVersionCode,
        skipped: Bool
    ) async throws(RuntimeWireError) {
        let service = updateServiceInstance()
        do {
            try await service.open()
        } catch {
            throw EmbeddedPackageService.wireError(for: error)
        }
        guard let packageID = PackageID(rawValue: wireID.rawValue) else {
            throw .store(
                "packageNotFound",
                message: "The package is not managed by APKRun.",
                remediation: "Use `apkrun list` to see managed packages.")
        }
        do {
            try await service.setSkippedVersion(
                packageID: packageID, versionCode: versionCode, skipped: skipped)
        } catch let error as RuntimeWireError {
            throw error
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }
    }
}

/// The `UpdateRuntimeAccess` the host supplies to UpdateCore (update-system.md
/// §7.5): runtime state from the supervisor, session presence from the
/// headless session service, readiness through `ensureReady(.automatic)`.
private actor EmbeddedUpdateRuntimeAccess: UpdateRuntimeAccess {
    private let stateOf: @Sendable () async -> WireRuntimeState
    private let inUse: @Sendable (PackageID) async -> Bool
    private let lastEnd: @Sendable (PackageID) async -> ContinuousClock.Instant?
    private let androidOK: @Sendable (PackageID) async -> Bool
    private let events: @Sendable () -> AsyncStream<UpdateRuntimeEvent>
    private let endAll: @Sendable (PackageID) async -> Void
    private let reopenPackage: @Sendable (PackageID) async throws -> Void
    private let ready: @Sendable (UpdateStartReason) async throws -> Void
    private let assertOperation: @Sendable () async throws -> UpdateActivityAssertion
    private let healthLaunch: @Sendable (PackageID, UpdateHealthCheckTimeouts) async -> HealthLaunchResult
    private let drawnFrame: @Sendable (PackageID) async -> Bool

    init(
        stateOf: @escaping @Sendable () async -> WireRuntimeState,
        inUse: @escaping @Sendable (PackageID) async -> Bool,
        lastEnd: @escaping @Sendable (PackageID) async -> ContinuousClock.Instant?,
        androidOK: @escaping @Sendable (PackageID) async -> Bool,
        events: @escaping @Sendable () -> AsyncStream<UpdateRuntimeEvent>,
        endAll: @escaping @Sendable (PackageID) async -> Void,
        reopenPackage: @escaping @Sendable (PackageID) async throws -> Void,
        ready: @escaping @Sendable (UpdateStartReason) async throws -> Void,
        assertOperation: @escaping @Sendable () async throws -> UpdateActivityAssertion,
        healthLaunch: @escaping @Sendable (PackageID, UpdateHealthCheckTimeouts) async -> UpdateCore.HealthLaunchResult,
        drawnFrame: @escaping @Sendable (PackageID) async -> Bool
    ) {
        self.stateOf = stateOf
        self.inUse = inUse
        self.lastEnd = lastEnd
        self.androidOK = androidOK
        self.events = events
        self.endAll = endAll
        self.reopenPackage = reopenPackage
        self.ready = ready
        self.assertOperation = assertOperation
        self.healthLaunch = healthLaunch
        self.drawnFrame = drawnFrame
    }

    var runtimeState: WireRuntimeState {
        get async { await stateOf() }
    }

    nonisolated var runtimeEvents: AsyncStream<UpdateRuntimeEvent> {
        events()
    }

    func androidAllowsGentleInstall(_ packageID: PackageID) async -> Bool {
        await androidOK(packageID)
    }

    func hasActiveUse(_ packageID: PackageID) async -> Bool {
        await inUse(packageID)
    }

    func lastSessionEnd(_ packageID: PackageID) async -> ContinuousClock.Instant? {
        await lastEnd(packageID)
    }

    func endSessions(for packageID: PackageID, reason: UpdateSessionEndReason) async {
        await endAll(packageID)
    }

    func reopen(_ packageID: PackageID) async {
        try? await reopenPackage(packageID)
    }

    func ensureReady(_ reason: UpdateStartReason) async throws {
        try await ready(reason)
    }

    func assertStoreOperation() async throws -> UpdateActivityAssertion {
        try await assertOperation()
    }

    /// §8.2: the session service runs the health launch when it knows how;
    /// a service without health-launch support answers `.launchFailed`, the
    /// same as no channel.
    func healthCheckLaunch(_ packageID: PackageID, timeouts: UpdateHealthCheckTimeouts) async
        -> HealthLaunchResult
    {
        await healthLaunch(packageID, timeouts)
    }

    func hasDrawnFrame(_ packageID: PackageID) async -> Bool {
        await drawnFrame(packageID)
    }
}

/// `updates.waiting` (diagnostics.md §7.4): a staged update waiting more
/// than 7 days reports `update.stagedTooLong` (error-catalog §20.3).
struct UpdatesWaitingCheck: HealthCheck {
    /// update-system.md §7.4's waiting period.
    static let staleAfter: TimeInterval = 7 * 24 * 3600

    let stateStore: UpdateStateStore

    var id: HealthCheckID { "updates.waiting" }
    var group: HealthGroup { .updates }
    var requirement: HealthRequirement { .host }
    var cost: HealthCost { .quick }
    var fix: (any HealthFix)? { nil }
    var title: LocalizedText {
        LocalizedText(key: "health.updates.waiting", fallback: "Waiting updates")
    }

    func run(_ context: HealthContext) async -> DiagnosticsCore.HealthResult {
        let states = await stateStore.allStates()
        let now = context.clock.now
        let stale = states.values.filter {
            $0.phase == "staged"
                && ($0.stagedAt.map { $0.addingTimeInterval(Self.staleAfter) < now } ?? false)
        }
        let stagedCount = states.values.count(where: { $0.phase == "staged" })
        guard let oldest = stale.first else {
            return DiagnosticsCore.HealthResult(
                id: id, group: group, state: .pass, title: title,
                detail: stagedCount == 0
                    ? "No update is waiting."
                    : "\(stagedCount) update(s) staged.",
                error: nil, measuredAt: now)
        }
        let app = oldest.candidate?.versionName ?? "unknown"
        return DiagnosticsCore.HealthResult(
            id: id, group: group, state: .warning, title: title,
            detail: "\(stale.count) update(s) staged for more than 7 days.",
            error: ErrorInfo(
                code: "update.stagedTooLong",
                message: LocalizedText(
                    key: "update.stagedTooLong",
                    parameters: ["app": .text(app)],
                    fallback: "An update of \(app) has been waiting for more than 7 days."),
                remediation: LocalizedText(
                    key: "update.stagedTooLong.remediation",
                    fallback: "Quit the app to install it, or choose Update Now."),
                action: .none),
            measuredAt: now)
    }
}

extension RuntimeHost {
    /// Test hook: installs the session service `updateRuntimeAccess` reads
    /// (T1 with fake sessions, update-system.md §7.5).
    func installHeadlessSessionServiceForTesting(_ service: any RuntimeSessionService) {
        headlessSessionService = service
    }

    /// Builds the §7.5 runtime access over this host's supervisor and
    /// headless session service.
    func updateRuntimeAccess() -> any UpdateRuntimeAccess {
        EmbeddedUpdateRuntimeAccess(
            stateOf: { [weak self] in
                guard let self, let supervisor = await self.supervisor else {
                    return .stopped
                }
                return Self.wireRuntimeState(for: await supervisor.state)
            },
            inUse: { [weak self] packageID in
                guard let self,
                    let handling = await self.headlessSessionService
                        as? any PackageMutationSessionHandling,
                    let wireID = RuntimePackageID(rawValue: packageID.rawValue)
                else {
                    return false
                }
                // GU2 + GU3: a live session or a keepRunning task.
                if await handling.hasActiveSession(packageID: wireID) {
                    return true
                }
                return await handling.hasBackgroundActivity(packageID: wireID)
            },
            lastEnd: { [weak self] packageID in
                guard let self,
                    let handling = await self.headlessSessionService
                        as? any PackageMutationSessionHandling,
                    let wireID = RuntimePackageID(rawValue: packageID.rawValue)
                else {
                    return nil
                }
                return await handling.lastSessionEnd(packageID: wireID)
            },
            androidOK: { [weak self] packageID in
                guard let self, let supervisor = await self.supervisor else {
                    return true
                }
                // Custom image: Store Agent op 110 (`store.constraints.v1`).
                // A channel without the capability answers nil and the
                // ListTasks fallback below decides (update-system.md §7.1).
                if let access = await self.storeAccessForUpdateConstraints(),
                    let answer = try? await access.withStoreAgent(UUID()) { channel -> Bool? in
                        guard channel.capabilities.contains(.constraints) else {
                            return nil
                        }
                        return try await channel.installConstraintsAllow(packageID)
                    }
                {
                    return answer
                }
                // Stock image: the guest's ListTasks snapshot — gentle when
                // no task of the package is on any display (GU5 fallback).
                guard let agent = await supervisor.developmentGuestAgent else {
                    return true
                }
                return await agent.tasks(forPackage: packageID.rawValue).isEmpty
            },
            events: { [weak self] in
                AsyncStream { continuation in
                    let streamID = UUID()
                    let pump = Task { [weak self] in
                        guard let self else { return }
                        // State changes ride the host's single
                        // `supervisor.events` consumer: a second iteration
                        // of the same stream would split the events and
                        // starve the host's own monitoring.
                        await self.registerUpdateEventContinuation(
                            streamID, continuation)
                        // The session service appears when the runtime is
                        // ready; retry until it does or the stream ends.
                        while !Task.isCancelled {
                            if let handling = await self.headlessSessionService
                                as? any PackageMutationSessionHandling
                            {
                                await handling.observeSessionActivity { packageID, activity in
                                    guard let id = PackageID(rawValue: packageID.rawValue)
                                    else { return }
                                    switch activity {
                                    case .started:
                                        continuation.yield(.sessionStarted(id))
                                    case .ended:
                                        continuation.yield(.sessionEnded(id))
                                    case .taskEnded:
                                        continuation.yield(.taskEnded(id))
                                    }
                                }
                                return
                            }
                            try? await Task.sleep(for: .seconds(3))
                        }
                    }
                    continuation.onTermination = { [weak self] _ in
                        pump.cancel()
                        Task { await self?.removeUpdateEventContinuation(streamID) }
                    }
                }
            },
            endAll: { [weak self] packageID in
                guard let self,
                    let handling = await self.headlessSessionService
                        as? any PackageMutationSessionHandling,
                    let wireID = RuntimePackageID(rawValue: packageID.rawValue)
                else {
                    return
                }
                await handling.endSessionForUpdate(packageID: wireID)
            },
            reopenPackage: { [weak self] packageID in
                guard let self,
                    let handling = await self.headlessSessionService
                        as? any PackageMutationSessionHandling,
                    let wireID = RuntimePackageID(rawValue: packageID.rawValue)
                else {
                    return
                }
                try await handling.reopenPackageSession(packageID: wireID)
            },
            ready: { [weak self] reason in
                guard let self, let supervisor = await self.supervisor else {
                    throw UpdateFailure.providerUnreachable(reason: "runtime is not running")
                }
                // §3.5: booting a stopped runtime for an automatic install is
                // allowed only under `updates.startRuntimeToInstall` while a
                // staged update has waited > 24 h on AC with the user idle
                // >= 15 min; otherwise the install defers to the next gate.
                if reason == .update, await supervisor.state == .stopped {
                    let globals = GlobalSettings.load(from: self.paths.settingsFile)
                    guard globals.updatesStartRuntimeToInstall else {
                        throw UpdateFailure.providerUnreachable(
                            reason: "updates.startRuntimeToInstall is off")
                    }
                    let cutoff = Date().addingTimeInterval(-86_400)
                    let staged = await self.updateServiceInstance().stateStore.allStates()
                        .values.contains {
                            $0.phase == "staged" && ($0.stagedAt ?? .distantFuture) < cutoff
                        }
                    guard staged else {
                        throw UpdateFailure.providerUnreachable(
                            reason: "no staged update older than 24 h")
                    }
                    guard Self.hostOnACPower(), Self.hostIdleSeconds() >= 900 else {
                        throw UpdateFailure.providerUnreachable(
                            reason: "§3.5 needs AC power and >=15 min idle")
                    }
                }
                // A user-initiated Update Now may resume a suspended runtime;
                // automatic installs go through .automatic (§7.1 GU1).
                try await supervisor.ensureReady(reason == .user ? .user : .automatic)
                // After a daemon restart or an Android stop the shared store's
                // runtime access is still detached: without this, a ready
                // Android answers every update install with runtimeUnavailable.
                do {
                    try await self.attachPackageQueriesIfRuntimeIsReady(
                        to: self.packageQueryServiceInstance())
                } catch {
                    throw UpdateFailure.providerUnreachable(
                        reason: "package channel is not connected")
                }
            },
            assertOperation: { [weak self] in
                guard let self else { return UpdateActivityAssertion() }
                // The host's package-mutation guard makes a stop, restart,
                // or reset wait for a queued install resuming without its
                // original client request.
                try await self.beginPackageMutation()
                let inner = await self.updateIdleController.assertActivity(.storeOperation)
                return UpdateActivityAssertion {
                    inner.release()
                    Task { await self.finishPackageMutation() }
                }
            },
            // §8.2: the session service runs the health-check launch; a
            // service without it answers `.launchFailed`, the same as no
            // channel.
            healthLaunch: { [weak self] packageID, timeouts in
                guard let self,
                    let service = await self.headlessSessionService
                        as? DaemonHeadlessSessionService,
                    let wireID = RuntimePackageID(rawValue: packageID.rawValue)
                else {
                    return .launchFailed(detail: "noSessionService")
                }
                return await service.healthCheckLaunch(
                    packageID: wireID, timeouts: timeouts)
            },
            drawnFrame: { [weak self] packageID in
                guard let self else { return false }
                if let service = await self.headlessSessionService
                    as? DaemonHeadlessSessionService,
                    let wireID = RuntimePackageID(rawValue: packageID.rawValue),
                    await service.hasDrawnFrame(packageID: wireID)
                {
                    return true
                }
                // §8.1: any earlier session that drew a frame — a FIRST_FRAME
                // marker persisted in perf/launches.jsonl — also proves the
                // app can draw, including across daemon restarts.
                return PerfRecordWriter.read(from: self.paths.launchPerformanceFile)
                    .contains { $0.packageID == packageID.rawValue && $0.outcome == "shown" }
            })
    }

    /// The §7.1 gentle-update gate shared by update installs, created with
    /// its §7.2 trigger pumps on first use.
    func updateGateInstance() -> GentleUpdateGate {
        if let updateGate { return updateGate }
        let gate = GentleUpdateGate(
            runtime: updateRuntimeAccess(),
            storeBusy: { [weak self] packageID in
                guard let self else { return false }
                return await self.packageQueryServiceInstance().store
                    .packageMutationInProgress(packageID)
            },
            // §8.2: the health launch reuses the session's display lease; a
            // pool with no free scanout answers `.launchFailed` rather than
            // blocking the install queue on a display slot.
            requiresDisplaySlot: { _ in false },
            displaySlotFree: { true })
        updateGate = gate
        startUpdateGatePump()
        Task { await self.wireUpdateGateSessionHooks() }
        return gate
    }

    /// Attaches the §7.2 session hooks once both the gate and the session
    /// service exist (either may be created first).
    func wireUpdateGateSessionHooks() async {
        guard let updateGate,
            let service = headlessSessionService as? DaemonHeadlessSessionService
        else {
            return
        }
        await service.setUpdateHooks(
            transactionWaiter: { [weak self] packageID in
                await self?.awaitUpdateInstall(for: packageID, gate: updateGate)
            },
            firstFrameObserver: { [weak self] packageID in
                guard let self, let package = PackageID(rawValue: packageID.rawValue) else { return }
                await self.updateServiceInstance().notePostUpdateFirstFrame(package)
                // runtime-daemon.md §7.1: a due package's check is scheduled
                // 30 s after the first frame — never before openSession
                // replies.
                await self.updateSchedulerInstance().noteLaunched(package)
            })
    }

    /// The §7.2 race from `openSession`: a pre-commit install is cancelled
    /// back to `staged`; a committing install is awaited up to 30 s and the
    /// session's first frame counts as H4 (runtime-daemon.md §7.1).
    private func awaitUpdateInstall(for packageID: RuntimePackageID, gate: GentleUpdateGate) async {
        guard let package = PackageID(rawValue: packageID.rawValue) else { return }
        switch await gate.installPhase(for: package) {
        case .preCommit?, nil:
            // nil covers the race where the install just finished.
            await gate.cancelInstall(package)
        case .committing:
            if await gate.awaitInstallFinish(package, timeout: .seconds(30)),
                let service = headlessSessionService as? DaemonHeadlessSessionService
            {
                await service.markPostUpdateLaunch(packageID.rawValue)
            }
        }
    }

    /// Adds or removes an internal §7.2 state subscriber; the host's
    /// single `supervisor.events` consumer feeds them.
    func registerUpdateEventContinuation(
        _ id: UUID,
        _ continuation: AsyncStream<UpdateRuntimeEvent>.Continuation
    ) {
        updateEventContinuations[id] = continuation
    }

    /// Drops an internal §7.2 state subscriber.
    func removeUpdateEventContinuation(_ id: UUID) {
        updateEventContinuations.removeValue(forKey: id)
    }

    /// Starts the §7.2 trigger pump once: runtime events plus the
    /// 10-minute staged+ready tick drain the queue.
    private func startUpdateGatePump() {
        guard updateGatePumpTask == nil else { return }
        let events = updateRuntimeAccess().runtimeEvents
        updateGatePumpTask = Task { [weak self] in
            for await _ in events {
                await self?.drainUpdateGate()
            }
        }
        updateGateTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                await self?.drainUpdateGate()
            }
        }
    }

    /// Admits each queued install and runs it; a package that lost its
    /// staged row frees the gate's slot. After the drain, the GU4 quiet
    /// timer re-arms for the earliest blocked package's quiet-period end.
    private func drainUpdateGate() async {
        let gate = updateGateInstance()
        // §7.4: the one-time "ready to install" notice for >7-day waits
        // rides on every trigger and the 10-minute tick.
        await updateServiceInstance().notifyOverdueStagedUpdates()
        var next = await gate.nextReadyPackage()
        while let packageID = next {
            let outcome = await updateServiceInstance().resumeStagedInstall(
                packageID, runtime: updateRuntimeAccess(), gate: gate)
            guard outcome == nil else {
                // A resumed install frees and re-drains the queue itself.
                next = nil
                continue
            }
            // Free the leaked admission and try the next queued package.
            next = await gate.finishInstall(packageID)
        }
        // GU4: re-evaluate exactly when the earliest quiet period ends so
        // an install blocked on `sessionEndedRecently` runs within its
        // 30-second window instead of waiting for the 10-minute tick.
        // A deadline that passed while an install holds the slot is left
        // to that install's finish path, which drains the queue itself —
        // re-arming for it would spin this drain until the install ends.
        updateGateQuietTask?.cancel()
        let installInFlight = await gate.installInFlight
        if let instant = await gate.nextQuietReevaluation(),
            instant > ContinuousClock.now || !installInFlight
        {
            updateGateQuietTask = Task { [weak self] in
                try? await Task.sleep(until: instant, clock: .continuous)
                guard !Task.isCancelled else { return }
                await self?.drainUpdateGate()
            }
        }
    }

    /// `updatePackage` (runtime-api.md §9.1): check and install one package
    /// now, or apply a manual file update when `options.files` is set.
    public func updatePackage(
        packageID wireID: RuntimePackageID,
        options: UpdateNowOptions,
        files: [FileHandle],
        operationID: RuntimeAPI.OperationID,
        requestPayload: Data,
        clientKind: RuntimeClientKind
    ) async throws(RuntimeWireError) -> (OperationHandle, WireUpdateOutcome?) {
        guard let packageID = PackageID(rawValue: wireID.rawValue) else {
            throw .store(
                "packageNotFound",
                message: "The package is not managed by APKRun.",
                remediation: "Use `apkrun list` to see managed packages.")
        }
        let service = updateServiceInstance()
        do {
            try await service.open()
        } catch {
            throw EmbeddedUpdateService.wireError(for: error)
        }

        let handle = OperationHandle(operationID: operationID, kind: .update)
        let snapshot = OperationSnapshot(
            operationID: operationID,
            kind: .update,
            packageID: wireID,
            requestFingerprint: RuntimeOperationRequestFingerprint.make(from: requestPayload),
            clientKind: clientKind,
            startedAt: Date(),
            progress: OperationProgress(stage: "updating", message: "Updating…")
        )
        trackedOperations[operationID] = RuntimeTrackedOperation(
            handle: handle,
            requestPayload: requestPayload,
            snapshot: snapshot,
            isCancellable: false,
            task: nil
        )
        eventHub.publishOperationEvent(.started(snapshot), operationID: operationID)

        // An update is a package mutation: it blocks stop/restart/reset like
        // installs and uninstalls do, so Android cannot be torn down while a
        // stage→install transaction is open.
        do {
            try beginPackageMutation()
        } catch {
            finishOperation(
                operationID, result: .failed(Self.sessionWireError(for: error)))
            throw Self.sessionWireError(for: error)
        }
        defer { finishPackageMutation() }

        let outcome: WireUpdateOutcome?
        do {
            if let sources = options.files {
                // A manual file update enters at `validating` (§7.1): import
                // the files into a ticket, then validate and install it.
                let preview = try await packageQueryServiceInstance().importPackage(
                    RuntimeImportPackageRequest(files: sources, origin: .cli),
                    files: files)
                guard let ticket = UUID(uuidString: preview.ticket.rawValue) else {
                    throw RuntimeWireError.store(
                        "importTicketNotFound",
                        message: "The APK preview is no longer valid.",
                        remediation: "Run the update again.")
                }
                switch preview.relation {
                case .downgrade:
                    throw RuntimeWireError.store(
                        "downgradeRefused",
                        message: "The APK is older than the installed version.",
                        remediation: "Choose a newer APK, or uninstall the app first.")
                // .otherSigner is not refused here: the update validator's
                // V3 check decides whether a signing rotation is allowed by
                // lineage capability, and refuses a plain mismatch itself.
                default:
                    break
                }
                outcome = try await service.updateFromFile(
                    packageID, ticket: ticket, runtime: updateRuntimeAccess(),
                    gate: updateGateInstance(),
                    closeRunningApp: options.closeRunningApp)
            } else {
                outcome = await service.updatePackageNow(
                    packageID,
                    context: service.providerContext(userInitiated: true),
                    runtime: updateRuntimeAccess(),
                    gate: updateGateInstance(),
                    closeRunningApp: options.closeRunningApp)
            }
        } catch {
            let wireError: RuntimeWireError
            if let error = error as? RuntimeWireError {
                wireError = error
            } else {
                wireError = EmbeddedUpdateService.wireError(for: error)
            }
            finishOperation(operationID, result: .failed(wireError))
            throw wireError
        }
        finishOperation(operationID, result: .succeeded(.none))
        return (handle, outcome)
    }
}

/// `NWPathMonitor` wrapper for the §3.4 network rules. `satisfied` starts
/// true — a check must not be skipped before the first sample; `inexpensive`
/// starts false so a background download defers until the path is known.
final class UpdatePathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.apkrun.update-path")
    private let lock = NSLock()
    private var satisfiedPath = true
    private var inexpensivePath = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.lock()
            self?.satisfiedPath = path.status == .satisfied
            self?.inexpensivePath = !path.isExpensive && !path.isConstrained
            self?.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    var satisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return satisfiedPath
    }

    var inexpensive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inexpensivePath
    }
}

extension RuntimeHost {
    /// `HIDIdleTime` equivalent (update-system.md §3.5): seconds since the
    /// last user input, via `CGEventSourceSecondsSinceLastEventType`.
    static func hostIdleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: anyEvent)
    }

    /// True while the Mac runs on external power (§3.5): IOPowerSources'
    /// "time remaining" sentinel for AC.
    static func hostOnACPower() -> Bool {
        IOPSGetTimeRemainingEstimate() == -2.0
    }
}
