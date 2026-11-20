import APKStoreCore
import Foundation

// The per-package update coordinator (update-system.md §5, state-machines.md §6).

/// A user-facing notification the host posts for an update event (§9).
public struct UpdateNotification: Sendable, Equatable {
    /// The package the notification is about.
    public var packageID: PackageID
    /// The package's display name.
    public var displayName: String
    /// The offered versionCode, when declared.
    public var versionCode: VersionCode?
    /// The offered versionName, when declared.
    public var versionName: String?

    /// Creates an update-available notification.
    public init(
        packageID: PackageID,
        displayName: String,
        versionCode: VersionCode?,
        versionName: String?
    ) {
        self.packageID = packageID
        self.displayName = displayName
        self.versionCode = versionCode
        self.versionName = versionName
    }
}

/// Posts user-facing update notifications. RuntimeHost's `HostNotifier`
/// implements it by relaying to APKRun.app over `hostNotifications` (§9).
public protocol HostNotificationSink: Sendable {
    /// Posts an "Update available" notification.
    func notifyUpdateAvailable(_ notification: UpdateNotification) async
}

/// The result of one coordinator check run.
public enum UpdateCheckOutcome: Sendable, Equatable {
    /// The provider has nothing newer.
    case upToDate
    /// A newer candidate exists; the run stopped at `available`.
    case available(UpdateCandidate)
    /// The check failed.
    case failed(UpdateFailure)
}

/// The result of one coordinator download run (update-system.md §5).
public enum UpdateDownloadOutcome: Sendable {
    /// The candidate's artifacts sit in `incoming/<ticket>/`, hashes verified.
    public struct Downloaded: Sendable {
        /// The store download ticket `inspect`/`stage` consume.
        public var ticket: UUID
        /// The artifact set the provider returned.
        public var artifact: PackageArtifact
    }

    /// The set downloaded and verified; validation continues from here.
    case downloaded(Downloaded)
    /// The download ended in `completed(.skipped(.downloadFailed))`.
    case failed(UpdateFailure)
}

/// Runs the update phase machine for one package at a time. The run covers
/// `checking` → `available` → `downloading`; validation, staging, install, and
/// health check arrive in the following steps of #39.
public actor UpdateCoordinator {
    /// The package store to read records and settings from.
    private let store: PackageStore
    /// The persisted update state.
    private let stateStore: UpdateStateStore
    /// The notification sink; nil in tests that do not need it.
    private let notifier: (any HostNotificationSink)?
    /// Whether `developer.enabled` is on (gates the local provider).
    private let developerModeEnabled: @Sendable () -> Bool
    /// `updates.checkIntervalHours` (§3.2); default 6.
    private let checkIntervalHours: Int
    /// The guest facts providers filter with.
    private let guestFacts: @Sendable () -> GuestFacts
    /// Injected for tests: the network-failure backoff (10 s, then 60 s, §5).
    private let downloadRetrySleep: @Sendable (TimeInterval) async -> Void
    /// Injected for tests: overrides `ProviderRegistry` resolution.
    private let providerFactory:
        (@Sendable (UpdateProviderRef) throws(UpdateFailure) -> any UpdateProvider)?
    /// The hard size cap of one downloaded set (§5); 8 GiB.
    private static let downloadSizeLimit: Int64 = 8 * 1_024 * 1_024 * 1_024
    /// The in-memory phase per package (transient phases are not persisted).
    private var phases: [PackageID: UpdatePhase] = [:]
    /// Notified whenever a package's phase changes (wire `updates` topic).
    public var onPhaseChange: (@Sendable (PackageID, UpdatePhase) -> Void)?

    /// Creates a coordinator.
    public init(
        store: PackageStore,
        stateStore: UpdateStateStore,
        notifier: (any HostNotificationSink)? = nil,
        developerModeEnabled: @escaping @Sendable () -> Bool = { false },
        checkIntervalHours: Int = 6,
        guestFacts: @escaping @Sendable () -> GuestFacts = { GuestFacts() },
        downloadRetrySleep: @escaping @Sendable (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        providerFactory:
            (@Sendable (UpdateProviderRef) throws(UpdateFailure) -> any UpdateProvider)?
        = nil
    ) {
        self.store = store
        self.stateStore = stateStore
        self.notifier = notifier
        self.developerModeEnabled = developerModeEnabled
        self.checkIntervalHours = checkIntervalHours
        self.guestFacts = guestFacts
        self.downloadRetrySleep = downloadRetrySleep
        self.providerFactory = providerFactory
    }

    /// The current phase of a package, restoring a persisted `available` or
    /// `staged` phase from state.json after a restart (§10.1).
    public func phase(for packageID: PackageID) async -> UpdatePhase? {
        if let phase = phases[packageID] { return phase }
        guard let row = await stateStore.state(for: packageID) else { return nil }
        switch row.phase {
        case "available":
            // The candidate object is not persisted; the next check rebuilds it.
            return .available(
                UpdateCandidate(
                    packageID: packageID,
                    provider: UpdateProviderRef(
                        type: row.candidate?.provider ?? .local,
                        configuration: .direct(url: "")),
                    declaredVersionCode: row.candidate?.versionCode,
                    declaredVersionName: row.candidate?.versionName,
                    artifacts: [],
                    cursor: row.cursor ?? ProviderCursor(type: .local, value: "")))
        case "staged":
            return .staged
        default:
            return nil
        }
    }

    /// Runs `checking` for one package (§5). Returns the check outcome and
    /// records scheduling fields plus one history line.
    public func check(
        _ packageID: PackageID,
        trigger: UpdateTrigger,
        context: ProviderContext,
        checkOnly: Bool = false
    ) async -> UpdateCheckOutcome {
        let started = Date()
        guard
            let record = try? await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            return .failed(.providerMetadataInvalid(detail: "package is not managed"))
        }
        guard record.updateAuthority == .apkrun else {
            return .failed(.authorityDoesNotAllowUpdates)
        }
        guard let providerRef = record.updateProvider else {
            return .failed(.providerNotConfigured)
        }
        let row = await stateStore.state(for: packageID) ?? PackageUpdateState()
        let installed = InstalledPackage(
            id: record.packageId,
            versionCode: record.versionCode,
            signerDigests: record.signingCertificates,
            lineage: record.signingLineage,
            guest: guestFacts(),
            lastCursor: row.cursor)

        setPhase(packageID, .checking)
        let settings = try? await store.packageSettings(for: packageID)
        do {
            let provider = try resolveProvider(providerRef)
            let candidate = try await provider.check(installed, context: context)
            guard let candidate else {
                await recordCheck(
                    row: row, record: record, outcome: .upToDate,
                    failures: 0, now: started, trigger: trigger)
                return .upToDate
            }

            // Save the cursor of every processed candidate (§4.2) and persist
            // the `available` phase (§10.1).
            let newCursor = candidate.cursor
            await stateStore.update(packageID) { state in
                state.lastCheckAt = started
                state.nextCheckAt = Self.nextCheck(
                    after: started, intervalHours: checkIntervalHours, failures: 0)
                state.consecutiveFailures = 0
                // A `--check-only` report does not consume the candidate: the
                // next real check must find it again (§4.2 cursors mark
                // processed candidates only).
                if !checkOnly {
                    state.cursor = newCursor
                }
                state.phase = "available"
                state.candidate = PackageUpdateState.CandidateSummary(
                    versionCode: candidate.declaredVersionCode,
                    versionName: candidate.declaredVersionName,
                    provider: candidate.provider.type)
            }
            setPhase(packageID, .available(candidate))

            // Mark the candidate notified only when a notifier actually
            // delivered it; otherwise the notification stays pending for the
            // next check (check-only runs never notify).
            if !checkOnly, settings?.updateMode == "notifyOnly",
                newCursor != row.notifiedCursor, let notifier
            {
                await notifier.notifyUpdateAvailable(
                    UpdateNotification(
                        packageID: packageID,
                        displayName: record.displayName,
                        versionCode: candidate.declaredVersionCode,
                        versionName: candidate.declaredVersionName))
                await stateStore.update(packageID) { $0.notifiedCursor = newCursor }
            }
            // TODO(#39): automatic continues into downloading → validating → staged.
            await appendHistory(
                record: record, to: candidate.declaredVersionCode,
                provider: providerRef.type, trigger: trigger,
                outcome: "available", failure: nil, started: started)
            await stateStore.flush()
            return .available(candidate)
        } catch let failure {
            let failures = row.consecutiveFailures + 1
            await stateStore.update(packageID) { state in
                state.lastCheckAt = started
                state.nextCheckAt = Self.nextCheck(
                    after: started, intervalHours: checkIntervalHours, failures: failures)
                state.consecutiveFailures = failures
                state.phase = nil
            }
            setPhase(packageID, .completed(.skipped(.checkFailed(failure))))
            await appendHistory(
                record: record, to: nil, provider: providerRef.type, trigger: trigger,
                outcome: "skipped.checkFailed", failure: failure.errorCode, started: started)
            await stateStore.flush()
            return .failed(failure)
        }
    }

    /// Runs `downloading` for a candidate (§5): a store download ticket, the
    /// provider stream with progress events, the per-file declared-hash check,
    /// and the §5 retry policy — a hash mismatch discards the set and retries
    /// once from scratch; a network failure retries twice (10 s, then 60 s).
    /// A failure ends the run in `completed(.skipped(.downloadFailed))` and
    /// appends the history line for the whole run.
    public func download(
        _ packageID: PackageID,
        candidate: UpdateCandidate,
        context: ProviderContext,
        trigger: UpdateTrigger,
        started: Date = Date()
    ) async -> UpdateDownloadOutcome {
        guard
            let record = try? await store.listManagedPackages()
                .first(where: { $0.packageId == packageID })
        else {
            let failure = UpdateFailure.providerMetadataInvalid(
                detail: "package is not managed")
            await finishFailedDownload(
                packageID, record: nil, candidate: candidate, failure: failure,
                trigger: trigger, started: started)
            return .failed(failure)
        }
        let declaredTotal = candidate.artifacts.reduce(Int64(0)) {
            $0 + ($1.size ?? 0)
        }
        guard declaredTotal <= Self.downloadSizeLimit else {
            let failure = UpdateFailure.tooLarge(
                bytes: declaredTotal, limit: Self.downloadSizeLimit)
            await finishFailedDownload(
                packageID, record: record, candidate: candidate, failure: failure,
                trigger: trigger, started: started)
            return .failed(failure)
        }

        let provider: any UpdateProvider
        do {
            provider = try resolveProvider(candidate.provider)
        } catch let failure {
            await finishFailedDownload(
                packageID, record: record, candidate: candidate, failure: failure,
                trigger: trigger, started: started)
            return .failed(failure)
        }

        var hashMismatchRetries = 1
        var networkRetries = 0
        while true {
            setPhase(packageID, .downloading(progress: 0))
            let result = await attemptDownload(
                provider, candidate: candidate,
                packageID: packageID, context: context)
            switch result {
            case .success(let downloaded):
                return .downloaded(downloaded)
            case .failure(let failure):
                switch failure {
                case .hashMismatch where hashMismatchRetries > 0:
                    hashMismatchRetries -= 1
                    continue
                case .providerUnreachable, .providerHTTPStatus, .providerRateLimited,
                    .downloadFailed
                where networkRetries < 2:
                    await downloadRetrySleep(networkRetries == 0 ? 10 : 60)
                    networkRetries += 1
                    continue
                default:
                    await finishFailedDownload(
                        packageID, record: record, candidate: candidate,
                        failure: failure,
                        trigger: trigger, started: started)
                    return .failed(failure)
                }
            }
        }
    }

    /// Packages due for a check now (§3.2): authority `apkrun` and no
    /// `nextCheckAt` in the future.
    public func duePackages(now: Date = Date()) async -> [PackageID] {
        let records = (try? await store.listManagedPackages()) ?? []
        let states = await stateStore.allStates()
        return records.filter { record in
            guard record.updateAuthority == .apkrun, record.updateProvider != nil else {
                return false
            }
            guard let next = states[record.packageId]?.nextCheckAt else { return true }
            return next <= now
        }.map(\.packageId)
    }

    // MARK: - Internals

    private func resolveProvider(
        _ ref: UpdateProviderRef
    ) throws(UpdateFailure) -> any UpdateProvider {
        if let providerFactory { return try providerFactory(ref) }
        return try ProviderRegistry.provider(
            for: ref, developerModeEnabled: developerModeEnabled())
    }

    /// One download attempt: open a ticket, stream into `incoming/<ticket>/`,
    /// then verify every provider-declared SHA-256 against the file on disk
    /// (§5). A declared file missing or mismatching is `.hashMismatch`; the set
    /// exceeding the 8 GiB cap on disk is `.tooLarge`. Any store write failure
    /// is `.downloadFailed`.
    private func attemptDownload(
        _ provider: any UpdateProvider,
        candidate: UpdateCandidate,
        packageID: PackageID,
        context: ProviderContext
    ) async -> Result<UpdateDownloadOutcome.Downloaded, UpdateFailure> {
        let ticketInfo: (ticket: UUID, directory: URL)
        do {
            ticketInfo = try await store.beginDownloadTicket(for: packageID)
        } catch {
            return .failure(.downloadFailed(reason: String(describing: error)))
        }
        let ticket = ticketInfo.ticket
        let destination = DownloadDestination(
            ticket: ticket, directory: ticketInfo.directory)

        let artifact: PackageArtifact
        do {
            artifact = try await provider.download(
                candidate, to: destination, context: context
            ) { [weak self] progress in
                let fraction: Double
                if let total = progress.bytesTotal, total > 0 {
                    fraction =
                        min(1, Double(progress.bytesWritten) / Double(total))
                } else {
                    fraction = 0
                }
                Task { await self?.setPhase(packageID, .downloading(progress: fraction)) }
            }
        } catch let failure {
            try? await store.discardDownload(ticket: ticket)
            return .failure(failure)
        }

        // Hash every artifact the provider declared a digest for (§5): the
        // digest covers the file as streamed, so a file that differs on disk
        // after the download is a mismatch.
        for declared in candidate.artifacts where declared.sha256 != nil {
            let file = ticketInfo.directory.appendingPathComponent(
                declared.url.lastPathComponent)
            let observed = Self.fileDigest(at: file)
            guard let observed, observed == declared.sha256 else {
                try? await store.discardDownload(ticket: ticket)
                return .failure(
                    .hashMismatch(artifact: declared.url.lastPathComponent))
            }
        }
        let diskTotal = ((try? FileManager.default.contentsOfDirectory(
            at: ticketInfo.directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []).reduce(Int64(0)) {
            $0 + Int64(
                (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard diskTotal <= Self.downloadSizeLimit else {
            try? await store.discardDownload(ticket: ticket)
            return .failure(
                .tooLarge(bytes: diskTotal, limit: Self.downloadSizeLimit))
        }
        return .success(
            UpdateDownloadOutcome.Downloaded(ticket: ticket, artifact: artifact))
    }

    private static func fileDigest(at url: URL) -> SHA256Digest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256Digest(data: data)
    }

    private func finishFailedDownload(
        _ packageID: PackageID,
        record: PackageRecord?,
        candidate: UpdateCandidate,
        failure: UpdateFailure,
        trigger: UpdateTrigger,
        started: Date
    ) async {
        await stateStore.update(packageID) { state in
            state.cursor = candidate.cursor
            state.phase = nil
            state.candidate = nil
        }
        setPhase(packageID, .completed(.skipped(.downloadFailed(failure))))
        if let record {
            await appendHistory(
                record: record, to: candidate.declaredVersionCode,
                provider: candidate.provider.type, trigger: trigger,
                outcome: "skipped.downloadFailed", failure: failure.errorCode,
                started: started)
        }
        await stateStore.flush()
    }

    private func setPhase(_ packageID: PackageID, _ phase: UpdatePhase) {
        phases[packageID] = phase
        onPhaseChange?(packageID, phase)
    }

    private func recordCheck(
        row _: PackageUpdateState,
        record: PackageRecord,
        outcome: SkipReason,
        failures: Int,
        now: Date,
        trigger: UpdateTrigger
    ) async {
        await stateStore.update(record.packageId) { state in
            state.lastCheckAt = now
            state.nextCheckAt = Self.nextCheck(
                after: now, intervalHours: checkIntervalHours, failures: failures)
            state.consecutiveFailures = failures
            state.phase = nil
            state.candidate = nil
        }
        setPhase(record.packageId, .completed(.skipped(outcome)))
        await appendHistory(
            record: record, to: nil, provider: record.updateProvider?.type,
            trigger: trigger, outcome: "skipped.\(outcome.name)", failure: nil, started: now)
        await stateStore.flush()
    }

    private func appendHistory(
        record: PackageRecord,
        to: VersionCode?,
        provider: ProviderType?,
        trigger: UpdateTrigger,
        outcome: String,
        failure: String?,
        started: Date
    ) async {
        let finished = Date()
        try? await stateStore.appendHistory(
            UpdateHistoryEntry(
                time: finished,
                packageID: record.packageId,
                from: record.versionCode,
                to: to,
                provider: provider,
                trigger: trigger,
                outcome: outcome,
                failure: failure,
                phaseDurationsMs: [
                    "checking": Int(finished.timeIntervalSince(started) * 1_000)
                ]))
    }

    /// `nextCheckAt = lastCheckAt + interval ± jitter`; failure backoff is
    /// 30 min, then 2 h, then the normal interval (§3.2).
    static func nextCheck(
        after: Date,
        intervalHours: Int,
        failures: Int
    ) -> Date {
        let interval: TimeInterval
        switch failures {
        case 0: interval = TimeInterval(intervalHours) * 3_600
        case 1: interval = 30 * 60
        case 2: interval = 2 * 3_600
        default: interval = TimeInterval(intervalHours) * 3_600
        }
        let jitter = interval * 0.1 * Double.random(in: -1...1)
        return after.addingTimeInterval(interval + jitter)
    }
}
