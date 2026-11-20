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
    /// Posts the §7.4 "ready to install; quit to update" notification.
    func notifyUpdateWaiting(_ notification: UpdateNotification) async
    /// Posts an "Update refused" notification for the V3 and V5 refusals of
    /// update-system.md §6 — a candidate whose signer or provider metadata
    /// does not match is the case the user needs to see.
    func notifyUpdateRefused(_ notification: UpdateNotification) async
    /// Posts the §8.3 "rolled back" notification — the failed version was
    /// reverted and will not be offered again; app data is untouched.
    func notifyUpdateRolledBack(_ notification: UpdateNotification) async
    /// Posts the §8.3 "update kept after a failed health check"
    /// notification: the user chooses Keep <new>, Roll Back, or
    /// Restore <old> (erases data) when no rollback mechanism exists.
    func notifyUpdateKeptAfterFailedHealthCheck(_ notification: UpdateNotification) async
}

extension HostNotificationSink {
    /// Sinks that cannot render the §8.3 notices may drop them; the phases
    /// and history still record the outcome.
    public func notifyUpdateRolledBack(_ notification: UpdateNotification) async {}
    public func notifyUpdateKeptAfterFailedHealthCheck(_ notification: UpdateNotification) async {}
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
    private let providerFactory: (@Sendable (UpdateProviderRef) throws(UpdateFailure) -> any UpdateProvider)?
    /// V1–V3 of §6; stateless, injectable for tests.
    private let validator: UpdateValidator
    /// H1's budget (§8.1): 30 s for Android to report the staged set.
    private let healthCheckBudget: Duration
    /// Injected for tests: the poll tick between H1 queries.
    private let healthCheckTickSleep: @Sendable () async -> Void
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
            (@Sendable (UpdateProviderRef) throws(UpdateFailure) -> any UpdateProvider)? = nil,
        validator: UpdateValidator = UpdateValidator(),
        healthCheckBudget: Duration = .seconds(30),
        healthCheckTickSleep: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .seconds(1))
        }
    ) {
        self.store = store
        self.stateStore = stateStore
        self.notifier = notifier
        self.developerModeEnabled = developerModeEnabled
        self.checkIntervalHours = checkIntervalHours
        self.guestFacts = guestFacts
        self.downloadRetrySleep = downloadRetrySleep
        self.providerFactory = providerFactory
        self.validator = validator
        self.healthCheckBudget = healthCheckBudget
        self.healthCheckTickSleep = healthCheckTickSleep
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
                // One `where` per pattern: a shared trailing clause binds the
                // last pattern only and the others would retry forever.
                case .providerUnreachable where networkRetries < 2,
                    .providerHTTPStatus where networkRetries < 2,
                    .providerRateLimited where networkRetries < 2,
                    .downloadFailed where networkRetries < 2:
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
        let diskTotal =
            ((try? FileManager.default.contentsOfDirectory(
                at: ticketInfo.directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []).reduce(Int64(0)) {
                $0
                    + Int64(
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

    /// The result of `validate`: the accepted report, or the refusing failure.
    public enum UpdateValidationOutcome: Sendable {
        /// The payload `install` consumes.
        public struct Validated: Sendable {
            /// The verified ticket the report and set belong to.
            public var ticket: UUID
            /// The preview `inspect(ticket:)` produced.
            public var preview: PackageImportPreview
            /// The accepted report, written to `staged/validation.json`.
            public var report: ValidationReport
        }

        /// The set passed V0–V3; the report was written into the ticket's set.
        case validated(Validated)
        /// A check refused; the ticket was discarded and the run closed
        /// `completed(.skipped(.validationFailed))`.
        case failed(UpdateFailure)
    }

    /// §6 validating: V0 inside `inspect(ticket:)`, then V1–V3 on the verified
    /// preview. The accepted `ValidationReport` is written as
    /// `validation.json` into the ticket's `incoming/` set so `stage` carries
    /// it into `staged/`. A refusal discards the ticket, saves the cursor, and
    /// closes the run `completed(.skipped(.validationFailed))` with one
    /// history line.
    /// - `explicitSelection`: true when the user picked this candidate itself
    ///   (a manual file update or `--from`); it lifts the V6 skip refusal.
    public func validate(
        _ packageID: PackageID,
        ticket: UUID,
        candidate: UpdateCandidate,
        trigger: UpdateTrigger,
        started: Date = Date(),
        explicitSelection: Bool = false
    ) async -> UpdateValidationOutcome {
        setPhase(packageID, .validating)
        let records = (try? await store.listManagedPackages()) ?? []
        guard let record = records.first(where: { $0.packageId == packageID }) else {
            let failure = UpdateFailure.providerMetadataInvalid(
                detail: "package is not managed")
            return await finishFailedValidation(
                packageID, ticket: ticket, record: nil, candidate: candidate,
                failure: failure, trigger: trigger, started: started)
        }

        // V0 — the intrinsic checks run inside inspect.
        let preview: PackageImportPreview
        do {
            preview = try await store.inspect(ticket: ticket)
        } catch {
            let failure = UpdateFailure.validation(detail: "intrinsic(\(error))")
            return await finishFailedValidation(
                packageID, ticket: ticket, record: record, candidate: candidate,
                failure: failure, trigger: trigger, started: started)
        }

        // V1–V6 — identity, ordering, signer continuity, provider hash and
        // metadata, and the skip list. The installed artifact set supplies
        // the lineage, permission, and target-SDK inputs.
        let installedSet = try? await store.installedArtifactSet(for: packageID)
        let skippedVersions = await stateStore.state(for: packageID)?.skippedVersions ?? []
        let report: ValidationReport
        do {
            report = try validator.validate(
                preview: preview, installed: record, candidate: candidate,
                installedSet: installedSet, skippedVersions: skippedVersions,
                explicitSelection: explicitSelection)
        } catch let refusal {
            return await finishFailedValidation(
                packageID, ticket: ticket, record: record, candidate: candidate,
                failure: refusal.failure, trigger: trigger, started: started,
                refusedCheck: refusal.checkID)
        }

        // The report rides the ticket set into staged/.
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try await store.writeTicketFile(
                ticket: ticket, name: "validation.json",
                contents: try encoder.encode(report))
        } catch {
            let failure = UpdateFailure.validation(
                detail: "validationReportWriteFailed(\(error))")
            return await finishFailedValidation(
                packageID, ticket: ticket, record: record, candidate: candidate,
                failure: failure, trigger: trigger, started: started)
        }
        return .validated(
            .init(ticket: ticket, preview: preview, report: report))
    }

    /// Closes a refused validation: discards the ticket set, saves the cursor,
    /// and reports `completed(.skipped(.validationFailed))` with one history
    /// line (§5).
    private func finishFailedValidation(
        _ packageID: PackageID,
        ticket: UUID,
        record: PackageRecord?,
        candidate: UpdateCandidate,
        failure: UpdateFailure,
        trigger: UpdateTrigger,
        started: Date,
        refusedCheck: String? = nil
    ) async -> UpdateValidationOutcome {
        try? await store.discardDownload(ticket: ticket)
        await stateStore.update(packageID) { state in
            state.cursor = candidate.cursor
            state.phase = nil
            state.candidate = nil
        }
        setPhase(packageID, .completed(.skipped(.validationFailed(failure))))
        if let record {
            await appendHistory(
                record: record, to: candidate.declaredVersionCode,
                provider: candidate.provider.type, trigger: trigger,
                outcome: "skipped.validationFailed", failure: failure.errorCode,
                started: started)
            // "Update refused" posts only for the V3 and V5 refusals (§9).
            if refusedCheck == "V3" || refusedCheck == "V5" {
                await notifier?.notifyUpdateRefused(
                    UpdateNotification(
                        packageID: packageID,
                        displayName: record.displayName,
                        versionCode: candidate.declaredVersionCode,
                        versionName: candidate.declaredVersionName))
            }
        }
        await stateStore.flush()
        return .failed(failure)
    }

    /// The result of `install` (§7–§8).
    public enum UpdateInstallOutcome: Sendable {
        /// Staged; the gate deferred the install while the app is in use (§7).
        case staged
        /// Installed and H1 confirmed.
        case installed(from: VersionCode, to: VersionCode)
        /// Rolled back to the previous set after a failed health check; the
        /// failed versionCode was skipped (§8.3–§8.4). App data is untouched.
        case rolledBack(UpdateFailure)
        /// The health check failed but no rollback ran — autoRollback is off
        /// or no mechanism exists; the new version stays installed (§8.3).
        case keptAfterFailedHealthCheck(UpdateFailure)
        /// The run ended with an install failure.
        case failed(UpdateFailure)
    }

    /// §7–§8 install: stage the validated ticket, wait out the
    /// not-in-use gate, `installStaged`, then H1 — Android reporting the
    /// staged versionCode and signer set within the health-check budget.
    /// A gated run stays `.staged`; H1's timeout lands in
    /// `keptAfterFailedHealthCheck` until #44 wires rollback.
    public func install(
        _ packageID: PackageID,
        validated: UpdateValidationOutcome.Validated,
        candidate: UpdateCandidate,
        trigger: UpdateTrigger,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate,
        started: Date = Date(),
        origin: ArtifactOrigin? = nil,
        closeRunningApp: Bool = false
    ) async -> UpdateInstallOutcome {
        let records = (try? await store.listManagedPackages()) ?? []
        guard let record = records.first(where: { $0.packageId == packageID }) else {
            return await finishFailedInstall(
                packageID, record: nil, cursor: candidate.cursor,
                candidateVersionCode: candidate.declaredVersionCode,
                provider: candidate.provider.type,
                failure: .providerMetadataInvalid(
                    detail: "package is not managed"),
                trigger: trigger, started: started)
        }
        let preview = validated.preview
        let staged = StagedUpdateInfo(
            versionCode: preview.versionCode,
            versionName: preview.versionName,
            setDigest: preview.artifactSet.setDigest,
            size: preview.artifactSet.files.reduce(Int64(0)) { $0 + $1.size },
            fileCount: preview.artifactSet.files.count,
            origin: origin
                ?? ArtifactOrigin(
                    type: ArtifactOriginType(rawValue: candidate.provider.type.rawValue) ?? .local,
                    url: candidate.artifacts.first?.url.absoluteString,
                    declaredDigests: candidate.artifacts.compactMap(\.sha256)))
        do {
            try await store.stage(ticket: validated.ticket, candidate: staged)
        } catch {
            return await finishFailedInstall(
                packageID, record: record, cursor: candidate.cursor,
                candidateVersionCode: candidate.declaredVersionCode,
                provider: candidate.provider.type,
                failure: .installFailed(detail: "stage(\(error))"),
                trigger: trigger, started: started)
        }
        setPhase(packageID, .staged)
        await stateStore.update(packageID) { state in
            state.phase = "staged"
            state.stagedAt = started
            state.candidate = PackageUpdateState.CandidateSummary(
                versionCode: preview.versionCode,
                versionName: preview.versionName,
                provider: candidate.provider.type,
                signerDigests: preview.artifactSet.signerDigests,
                cursor: candidate.cursor,
                reopenAfterInstall: closeRunningApp)
        }
        await stateStore.flush()

        // §7.3 "Update Now": end the package's sessions with `.updating`
        // before the gate evaluates, so GU2/GU3 see the app as closed.
        if closeRunningApp {
            await runtime.endSessions(for: packageID, reason: .updating)
        }

        // §7.1–§7.2: the gentle gate admits the install or queues it as
        // `staged`; user-initiated runs jump ahead of automatic ones.
        let userInitiated = trigger == .userInitiated || trigger == .manual
        // §7.3: a user-initiated update brings Android up before the gate
        // evaluates GU1; an automatic run waits for a ready runtime.
        if userInitiated, await runtime.runtimeState != .ready {
            try? await runtime.ensureReady(.user)
        }
        guard await gate.requestInstall(packageID, userInitiated: userInitiated) else {
            // A request queued behind an in-flight admission is not
            // re-evaluated when that admission fails; drain the queue in
            // the background so an open package does not wait for the
            // 10-minute tick.
            Task.detached {
                await self.drainQueuedInstalls(
                    trigger: trigger, runtime: runtime, gate: gate)
            }
            return .staged
        }
        return await runGatedInstall(
            packageID, record: record,
            expectedVersionCode: preview.versionCode,
            expectedSigners: Set(preview.artifactSet.signerDigests),
            provider: candidate.provider.type, cursor: candidate.cursor,
            trigger: trigger, runtime: runtime, gate: gate, started: started,
            reopenAfterInstall: closeRunningApp)
    }

    /// §7.2 trigger: resumes a staged install the gate now admits.
    /// Returns `nil` while the gate stays closed or the package has no
    /// staged candidate.
    @discardableResult
    public func resumeStagedInstall(
        _ packageID: PackageID,
        trigger: UpdateTrigger = .scheduled,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate,
        started: Date = Date()
    ) async -> UpdateInstallOutcome? {
        guard let row = await stateStore.state(for: packageID),
            row.phase == "staged",
            let summary = row.candidate,
            let expectedVersionCode = summary.versionCode
        else {
            return nil
        }
        let records = (try? await store.listManagedPackages()) ?? []
        guard let record = records.first(where: { $0.packageId == packageID }) else {
            return nil
        }
        // The pump already admitted the package via `nextReadyPackage`;
        // install it without re-entering the queue.
        return await runGatedInstall(
            packageID, record: record,
            expectedVersionCode: expectedVersionCode,
            expectedSigners: Set(summary.signerDigests ?? []),
            provider: summary.provider, cursor: summary.cursor,
            trigger: trigger, runtime: runtime, gate: gate, started: started,
            reopenAfterInstall: summary.reopenAfterInstall)
    }

    /// §7.4: a candidate staged longer than `stagedNoticeAfter` gets one
    /// "ready to install; quit to update" notification per stage. The
    /// trigger pump calls this every §7.2 tick.
    public func notifyOverdueStagedUpdates(now: Date = Date()) async {
        guard let notifier else { return }
        for (packageID, row) in await stateStore.allStates() {
            guard row.phase == "staged",
                let stagedAt = row.stagedAt,
                stagedAt.addingTimeInterval(Self.stagedNoticeAfter) < now,
                row.waitingNotifiedAt == nil
            else {
                continue
            }
            let records = (try? await store.listManagedPackages()) ?? []
            guard let record = records.first(where: { $0.packageId == packageID }) else {
                continue
            }
            await notifier.notifyUpdateWaiting(
                UpdateNotification(
                    packageID: packageID,
                    displayName: record.displayName,
                    versionCode: row.candidate?.versionCode,
                    versionName: row.candidate?.versionName))
            await stateStore.update(packageID) { $0.waitingNotifiedAt = now }
        }
    }

    /// §7.4's waiting period before the one-time notice fires.
    static let stagedNoticeAfter: TimeInterval = 7 * 24 * 3600

    /// The post-gate portion of an install: ensure the runtime is up,
    /// hold the `storeOperation` assertion, run `installStaged`, then H1 —
    /// Android reporting the staged versionCode and signer set within the
    /// health-check budget.
    private func runGatedInstall(
        _ packageID: PackageID,
        record: PackageRecord,
        expectedVersionCode: VersionCode,
        expectedSigners: Set<SHA256Digest>,
        provider: ProviderType,
        cursor: ProviderCursor?,
        trigger: UpdateTrigger,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate,
        started: Date,
        reopenAfterInstall: Bool = false
    ) async -> UpdateInstallOutcome {
        // Automatic runs need a ready runtime (§3.5).
        do {
            try await runtime.ensureReady(.update)
        } catch {
            Task.detached {
                await self.pumpQueuedInstalls(
                    after: packageID, trigger: trigger, runtime: runtime, gate: gate)
            }
            return await finishFailedInstall(
                packageID, record: record, cursor: cursor,
                candidateVersionCode: expectedVersionCode, provider: provider,
                failure: .installFailed(detail: "runtimeUnavailable(\(error))"),
                trigger: trigger, started: started)
        }

        // §7.2: the install runs under a `storeOperation` assertion, which
        // also holds the host's package-mutation guard so a stop or restart
        // waits for the install.
        let assertion: UpdateActivityAssertion
        do {
            assertion = try await runtime.assertStoreOperation()
        } catch {
            Task.detached {
                await self.pumpQueuedInstalls(
                    after: packageID, trigger: trigger, runtime: runtime, gate: gate)
            }
            return await finishFailedInstall(
                packageID, record: record, cursor: cursor,
                candidateVersionCode: expectedVersionCode, provider: provider,
                failure: .installFailed(detail: "assertStoreOperation(\(error))"),
                trigger: trigger, started: started)
        }
        // §7.2 race boundary: the install stays `preCommit` while it
        // streams, so a session that opens cancels it back to `staged`;
        // `installStaged` runs `requestCommit` at the real commit point,
        // after which a session waits up to 30 s (runtime-daemon.md §7.1).
        let outcome = await performGatedInstall(
            packageID, record: record,
            expectedVersionCode: expectedVersionCode,
            expectedSigners: expectedSigners, provider: provider,
            cursor: cursor, trigger: trigger, runtime: runtime,
            gate: gate, started: started)
        assertion.release()
        // Free the gate's slot before anything that can open a session:
        // a launch while the install still holds its slot waits for it.
        let next = await gate.finishInstall(packageID)
        // §7.3: "Update Now" reopens the app after a successful update,
        // and its caller returns once its own install is done; unrelated
        // queued installs drain in the background.
        if case .installed = outcome, reopenAfterInstall {
            await runtime.reopen(packageID)
        }
        Task.detached {
            await self.drainQueuedInstalls(
                first: next, trigger: trigger, runtime: runtime, gate: gate)
        }
        return outcome
    }

    /// Frees the finished install's gate slot, then drains the queue
    /// starting at the package the slot's release admitted.
    private func pumpQueuedInstalls(
        after packageID: PackageID,
        trigger: UpdateTrigger,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate
    ) async {
        let first = await gate.finishInstall(packageID)
        await drainQueuedInstalls(
            first: first, trigger: trigger, runtime: runtime, gate: gate)
    }

    /// Admits each queued install and runs it; a package that lost its
    /// staged row frees the gate's slot. A resumed install continues the
    /// chain itself. `first` is a package a `finishInstall` already
    /// admitted — skipping it would leave its claim dangling.
    private func drainQueuedInstalls(
        first: PackageID? = nil,
        trigger: UpdateTrigger,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate
    ) async {
        var next = first
        if next == nil {
            next = await gate.nextReadyPackage()
        }
        while let admitted = next {
            if await resumeStagedInstall(
                admitted, trigger: trigger, runtime: runtime, gate: gate
            ) != nil {
                return
            }
            // No staged row for the admitted package: free its slot and
            // try the one after it.
            next = await gate.finishInstall(admitted)
        }
    }

    /// `installStaged` plus the H1 confirmation, called with the gate's
    /// admission and the `storeOperation` assertion already held.
    private func performGatedInstall(
        _ packageID: PackageID,
        record: PackageRecord,
        expectedVersionCode: VersionCode,
        expectedSigners: Set<SHA256Digest>,
        provider: ProviderType,
        cursor: ProviderCursor?,
        trigger: UpdateTrigger,
        runtime: any UpdateRuntimeAccess,
        gate: GentleUpdateGate,
        started: Date
    ) async -> UpdateInstallOutcome {

        setPhase(packageID, .installing)
        let updated: PackageRecord
        do {
            updated = try await store.installStaged(
                for: packageID, enableRollback: true,
                hasOpenSession: { await runtime.hasActiveUse(packageID) },
                commitGate: { await gate.requestCommit(packageID) })
        } catch PackageStoreFailure.packageInUse {
            // The gate closed between the check and the call: stay staged.
            setPhase(packageID, .staged)
            return .staged
        } catch {
            return await finishFailedInstall(
                packageID, record: record, cursor: cursor,
                candidateVersionCode: expectedVersionCode, provider: provider,
                failure: .installFailed(detail: "\(error)"),
                trigger: trigger, started: started)
        }

        // §8.1 health check (H1–H4 at the level of §8.1), then §8.3 outcomes.
        setPhase(packageID, .healthChecking)
        let settings = try? await store.packageSettings(for: packageID)
        let launchEnabled = settings?.update["healthCheckLaunch"] != "false"
        let autoRollback = settings?.update["autoRollback"] != "false"
        let hasLauncher =
            ((try? await store.installedPackageInfo(packageID))?.launchableComponent) != nil
        let level = HealthCheckLevel.level(
            hasLauncherActivity: hasLauncher,
            healthCheckLaunchEnabled: launchEnabled,
            hasProducedFrame: await runtime.hasDrawnFrame(packageID))
        let checker = UpdateHealthChecker(
            installedInfo: { packageID in
                try await self.store.installedPackageInfo(packageID)
            },
            launch: { packageID, timeouts in
                await runtime.healthCheckLaunch(packageID, timeouts: timeouts)
            },
            sleep: { _ in await self.healthCheckTickSleep() })
        if let healthFailure = await checker.run(
            packageID,
            expectedVersionCode: expectedVersionCode,
            expectedSigners: expectedSigners,
            level: level,
            timeouts: UpdateHealthCheckTimeouts(metadata: healthCheckBudget))
        {
            return await finishFailedHealthCheck(
                packageID, record: record, cursor: cursor,
                expectedVersionCode: expectedVersionCode,
                provider: provider, trigger: trigger,
                healthFailure: healthFailure,
                autoRollback: autoRollback, started: started)
        }

        await stateStore.update(packageID) { state in
            state.cursor = cursor
            state.phase = nil
            state.candidate = nil
            state.stagedAt = nil
        }
        let outcome = UpdateOutcome.updated(
            from: record.versionCode, to: updated.versionCode)
        setPhase(packageID, .completed(outcome))
        await appendHistory(
            record: record, to: updated.versionCode,
            provider: provider, trigger: trigger,
            outcome: "updated", failure: nil, started: started)
        await stateStore.flush()
        return .installed(from: record.versionCode, to: updated.versionCode)
    }

    /// §8.3: the health check failed after a successful install. With
    /// `update.autoRollback` on (the default) the store rolls back to the
    /// previous set and the failed versionCode is skipped. A rollback that
    /// cannot run — no mechanism or no previous set — keeps the update and
    /// notifies the user; one that runs and fails marks the package
    /// `broken`. With autoRollback off the update stays installed and the
    /// user gets the kept notification. App data is never rolled back.
    private func finishFailedHealthCheck(
        _ packageID: PackageID,
        record: PackageRecord,
        cursor: ProviderCursor?,
        expectedVersionCode: VersionCode,
        provider: ProviderType?,
        trigger: UpdateTrigger,
        healthFailure: HealthCheckFailure,
        autoRollback: Bool,
        started: Date
    ) async -> UpdateInstallOutcome {
        let failure = UpdateFailure.healthCheckFailed(detail: healthFailure.detail)
        let reason = RollbackReason.healthCheckFailed(failure)
        await stateStore.update(packageID) { state in
            state.cursor = cursor
            state.phase = nil
            state.candidate = nil
            state.stagedAt = nil
        }
        if autoRollback {
            setPhase(packageID, .rollingBack(reason))
            do {
                _ = try await store.rollback(
                    packageID: packageID, allowDataLoss: false,
                    reason: "healthCheck.\(healthFailure.step)")
                try? await store.recordHealth(packageID, result: .failed)
                await stateStore.update(packageID) { state in
                    if !state.skippedVersions.contains(expectedVersionCode) {
                        state.skippedVersions.append(expectedVersionCode)
                    }
                }
                setPhase(packageID, .completed(.rolledBack(reason: reason)))
                await appendHistory(
                    record: record, to: expectedVersionCode,
                    provider: provider, trigger: trigger,
                    outcome: "rolledBack", failure: failure.errorCode,
                    started: started)
                await notifier?.notifyUpdateRolledBack(
                    UpdateNotification(
                        packageID: packageID, displayName: record.displayName,
                        versionCode: expectedVersionCode, versionName: nil))
                await stateStore.flush()
                return .rolledBack(failure)
            } catch PackageStoreFailure.rollbackUnavailable {
                // §8.3: no mechanism or no previous set — keep the update;
                // the notification offers Keep <new> / Restore <old> (erases
                // data).
            } catch PackageStoreFailure.rollbackFailed(let detail) {
                try? await store.markBroken(packageID, reason: .rollbackFailed)
                return await finishFailedInstall(
                    packageID, record: record, cursor: cursor,
                    candidateVersionCode: expectedVersionCode, provider: provider,
                    failure: .rollbackFailed(detail: detail),
                    trigger: trigger, started: started)
            } catch {
                try? await store.markBroken(packageID, reason: .rollbackFailed)
                return await finishFailedInstall(
                    packageID, record: record, cursor: cursor,
                    candidateVersionCode: expectedVersionCode, provider: provider,
                    failure: .rollbackFailed(detail: "\(error)"),
                    trigger: trigger, started: started)
            }
        }
        // Kept: autoRollback off, or rollback unavailable (§8.3). The user
        // rolls back manually (`apkrun rollback`, §8.5) or restores the old
        // version accepting data loss.
        try? await store.recordHealth(packageID, result: .failed)
        setPhase(packageID, .completed(.keptAfterFailedHealthCheck(reason: reason)))
        await appendHistory(
            record: record, to: expectedVersionCode,
            provider: provider, trigger: trigger,
            outcome: "keptAfterFailedHealthCheck", failure: failure.errorCode,
            started: started)
        await notifier?.notifyUpdateKeptAfterFailedHealthCheck(
            UpdateNotification(
                packageID: packageID, displayName: record.displayName,
                versionCode: expectedVersionCode, versionName: nil))
        await stateStore.flush()
        return .keptAfterFailedHealthCheck(failure)
    }

    /// The result of a §8.5 user-initiated rollback.
    public enum UpdateRollbackOutcome: Sendable, Equatable {
        /// Rolled back to the given version; the current one was skipped.
        case rolledBack(to: VersionCode)
        /// No `previous/` set or no rollback mechanism (§7.3).
        case unavailable
        /// The rollback ran and failed; the package is `broken`.
        case failed(UpdateFailure)
    }

    /// §8.5: the user asked to roll back to `previous/`
    /// (`apkrun rollback <package>`). Runs the same `rollingBack` phase and
    /// store operation as a health-check rollback with `.userRequested` as
    /// the reason, and skips the rolled-back version. `allowDataLoss`
    /// permits the §7.3 uninstall + first-install fallback; only the
    /// confirmed "Restore (erases data)" path may pass true.
    public func rollbackPackage(
        _ packageID: PackageID,
        allowDataLoss: Bool = false
    ) async throws -> UpdateRollbackOutcome {
        let records = (try? await store.listManagedPackages()) ?? []
        guard let record = records.first(where: { $0.packageId == packageID }) else {
            throw PackageStoreFailure.packageNotFound
        }
        let started = Date()
        let reason = RollbackReason.userRequested
        setPhase(packageID, .rollingBack(reason))
        do {
            let restored = try await store.rollback(
                packageID: packageID, allowDataLoss: allowDataLoss,
                reason: "userRequested")
            await stateStore.skipVersion(packageID, versionCode: record.versionCode)
            setPhase(packageID, .completed(.rolledBack(reason: reason)))
            await appendHistory(
                record: record, to: record.versionCode,
                provider: record.updateProvider?.type, trigger: .manual,
                outcome: "rolledBack", failure: nil, started: started)
            await notifier?.notifyUpdateRolledBack(
                UpdateNotification(
                    packageID: packageID, displayName: record.displayName,
                    versionCode: record.versionCode, versionName: record.versionName))
            await stateStore.flush()
            return .rolledBack(to: restored.versionCode)
        } catch PackageStoreFailure.rollbackUnavailable {
            setPhase(packageID, .completed(.keptAfterFailedHealthCheck(reason: reason)))
            await appendHistory(
                record: record, to: record.versionCode,
                provider: record.updateProvider?.type, trigger: .manual,
                outcome: "rollbackUnavailable", failure: nil, started: started)
            await stateStore.flush()
            return .unavailable
        } catch PackageStoreFailure.rollbackFailed(let detail) {
            try? await store.markBroken(packageID, reason: .rollbackFailed)
            let failure = UpdateFailure.rollbackFailed(detail: detail)
            setPhase(packageID, .completed(.skipped(.installFailed(failure))))
            await appendHistory(
                record: record, to: record.versionCode,
                provider: record.updateProvider?.type, trigger: .manual,
                outcome: "rollbackFailed", failure: failure.errorCode, started: started)
            await stateStore.flush()
            return .failed(failure)
        }
    }

    /// Closes a failed install: saves the cursor and reports
    /// `completed(.skipped(.installFailed))` with one history line.
    private func finishFailedInstall(
        _ packageID: PackageID,
        record: PackageRecord?,
        cursor: ProviderCursor?,
        candidateVersionCode: VersionCode?,
        provider: ProviderType?,
        failure: UpdateFailure,
        trigger: UpdateTrigger,
        started: Date
    ) async -> UpdateInstallOutcome {
        await stateStore.update(packageID) { state in
            state.cursor = cursor
            state.phase = nil
            state.candidate = nil
            state.stagedAt = nil
        }
        setPhase(packageID, .completed(.skipped(.installFailed(failure))))
        if let record {
            await appendHistory(
                record: record, to: candidateVersionCode,
                provider: provider, trigger: trigger,
                outcome: "skipped.installFailed", failure: failure.errorCode,
                started: started)
        }
        await stateStore.flush()
        return .failed(failure)
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
