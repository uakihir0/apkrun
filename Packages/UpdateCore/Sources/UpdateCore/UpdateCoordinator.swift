import Foundation

import APKStoreCore

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

/// Runs the update phase machine for one package at a time. For this task the
/// run covers `checking` → `available` or `completed(.skipped(*))`; download,
/// validation, staging, install, and health check arrive in #39.
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
        guestFacts: @escaping @Sendable () -> GuestFacts = { GuestFacts() }
    ) {
        self.store = store
        self.stateStore = stateStore
        self.notifier = notifier
        self.developerModeEnabled = developerModeEnabled
        self.checkIntervalHours = checkIntervalHours
        self.guestFacts = guestFacts
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
        context: ProviderContext
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
            let provider = try ProviderRegistry.provider(
                for: providerRef, developerModeEnabled: developerModeEnabled())
            let candidate = try await provider.check(installed, context: context)
            guard let candidate else {
                await recordCheck(row: row, record: record, outcome: .upToDate,
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
                state.cursor = newCursor
                state.phase = "available"
                state.candidate = PackageUpdateState.CandidateSummary(
                    versionCode: candidate.declaredVersionCode,
                    versionName: candidate.declaredVersionName,
                    provider: candidate.provider.type)
            }
            setPhase(packageID, .available(candidate))

            if settings?.updateMode == "notifyOnly", newCursor != row.notifiedCursor {
                await notifier?.notifyUpdateAvailable(
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
        let jitter = interval * 0.1 * Double.random(in: -1 ... 1)
        return after.addingTimeInterval(interval + jitter)
    }
}
