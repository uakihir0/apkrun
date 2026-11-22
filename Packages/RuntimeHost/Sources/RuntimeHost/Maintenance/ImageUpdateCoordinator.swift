import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeAPI

/// Owns the Android image update phase machine and `Images/update-state.json`
/// (runtime-maintenance.md §4.3). It is the file's only writer, decides when a
/// `ready` image may be applied, records rejections and rollbacks (§4.8), and
/// computes the set of versions `ImageStore.garbageCollect` must keep (§4.9).
///
/// The feed check, download, and gate that feed this actor arrive with #88; for
/// now entries come from `apkrun image install` and the rollback command.
public actor ImageUpdateCoordinator {
    /// Rejected versions drop off the rejection list after seven days (§4.8).
    public static let rejectionRetention: TimeInterval = 7 * 24 * 60 * 60

    private let stateFile: URL
    private let publish: @Sendable (MaintenanceEvent) -> Void
    /// Migrates Android to the given version: stops, migrates, boots the new
    /// image and runs its health check, restoring the previous image on
    /// failure. Throws `ImageFailure`.
    private let migrate: @Sendable (ImageCore.ImageVersion, UUID, Bool) async throws -> Void
    private var state: ImageUpdateState
    private let logger: APKLogger
    private let clock: @Sendable () -> Date
    private var applyTask: Task<Void, Error>?

    /// Creates the coordinator; `reconcile(currentImage:)` must run once before
    /// use so an interrupted `applying` phase is settled.
    public init(
        paths: APKRunPaths,
        diagnostics: DiagnosticsContext,
        publish: @escaping @Sendable (MaintenanceEvent) -> Void,
        migrate: @escaping @Sendable (ImageCore.ImageVersion, UUID, Bool) async throws -> Void,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        stateFile = paths.imageUpdateStateFile
        self.publish = publish
        self.migrate = migrate
        self.clock = clock
        state = (try? Self.load(from: paths.imageUpdateStateFile)) ?? ImageUpdateState()
        logger = APKLogger(category: MaintenanceLogCategory.imageUpdate, sink: diagnostics.logSink)
    }

    /// The persisted state, for `apkrun image` and the Settings surface.
    public func stateSnapshot() -> ImageUpdateState {
        state
    }

    /// Settles a persisted `applying` phase against the image that is actually
    /// current after a restart (runtime-maintenance.md §4.3).
    public func reconcile(currentImage: ImageCore.ImageVersion?) {
        pruneExpiredRejections()
        guard case .applying(let from, let to) = state.phase else { return }
        if currentImage == to {
            state.phase = .idle
            state.lastResult = .installed(to)
            state.lastAutomaticApplyAt = clock()
        } else if currentImage == from {
            // The migration was interrupted and the supervisor restored A.
            state.phase = .idle
            state.lastResult = .rejected(to, reason: .migrationFailed)
            state.rejected[to.description] = RejectedImage(
                version: to, at: clock(), reason: .migrationFailed
            )
        } else {
            state.phase = .failed(state.candidate, reason: "image.migrationInterrupted", retryAt: nil)
        }
        state.candidate = nil
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
        logger.notice("Reconciled an interrupted image update to phase \(state.phase.phaseDescription, .public)")
    }

    /// Records a newly installed image as `ready` (§4.3). Called by the host
    /// after `ImageStore.install`.
    public func noteReady(_ version: ImageCore.ImageVersion) {
        state.phase = .ready(version)
        state.readyAt = clock()
        state.downloadFailures = 0
        state.installFailures = 0
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    /// Whether a version is on the rejection list (§4.8).
    public func isRejected(_ version: ImageCore.ImageVersion) -> Bool {
        state.rejected[version.description] != nil
    }

    /// Applies `version`, which must be installed (§4.8): runs the migration
    /// through the injected supervisor hook and records the outcome. `from` is
    /// the currently installed image. Rejected versions are refused unless
    /// `force` is set (`retryRejected`, `rollback`).
    public func apply(
        _ version: ImageCore.ImageVersion,
        from: ImageCore.ImageVersion,
        operationID: UUID = UUID(),
        force: Bool = false,
        restoring: Bool = false
    ) async throws(ImageFailure) {
        guard applyTask == nil else {
            throw .imageUpdateBusy(detail: "an apply is already running")
        }
        if !force, let rejection = state.rejected[version.description] {
            throw .imageRejected(version: version.description, reason: rejection.reason.rawValue)
        }
        let task = Task { [self, migrate] in
            do {
                logger.notice(
                    "IMAGE_MIGRATION_START \(version.description, .public) operation \(operationID.uuidString, .public)"
                )
                await self.setPhase(.applying(from: from, to: version))
                try await migrate(version, operationID, restoring)
                await self.noteInstalled(version)
            } catch let failure as ImageFailure {
                await self.noteApplyFailed(version, error: failure, restoreFailure: restoring)
                throw failure
            } catch {
                let failure = ImageFailure.imageUpdateBusy(detail: "\(error)")
                await self.noteApplyFailed(version, error: failure, restoreFailure: restoring)
                throw failure
            }
        }
        applyTask = task
        do {
            try await task.value
        } catch let failure as ImageFailure {
            applyTask = nil
            throw failure
        } catch {
            applyTask = nil
            throw .imageUpdateBusy(detail: "\(error)")
        }
        applyTask = nil
    }

    /// Goes back to the previously installed image (§4.8): migrates to
    /// `previous`, and on success marks the abandoned version `userRolledBack`.
    public func rollback(
        to previous: ImageCore.ImageVersion,
        abandoned: ImageCore.ImageVersion,
        operationID: UUID = UUID()
    ) async throws(ImageFailure) {
        try await apply(previous, from: abandoned, operationID: operationID, force: true, restoring: true)
        logger.notice("IMAGE_ROLLBACK_END \(previous.description, .public) abandoned \(abandoned.description, .public)")
        state.rejected[abandoned.description] = RejectedImage(
            version: abandoned, at: clock(), reason: .userRolledBack
        )
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    /// Applies a rejected version again (§4.8 `retryRejected`).
    public func retryRejected(
        _ version: ImageCore.ImageVersion,
        from current: ImageCore.ImageVersion,
        operationID: UUID = UUID()
    ) async throws(ImageFailure) {
        try await apply(version, from: current, operationID: operationID, force: true)
    }

    /// The versions `ImageStore.garbageCollect` must keep on top of
    /// `current`/`previous` (§4.9): the `ready` image plus rejections younger
    /// than seven days.
    public func gcRetainSet() -> Set<ImageCore.ImageVersion> {
        var keep: Set<ImageCore.ImageVersion> = []
        if case .ready(let version) = state.phase {
            keep.insert(version)
        }
        if case .applying(_, let to) = state.phase {
            keep.insert(to)
        }
        let cutoff = clock().addingTimeInterval(-Self.rejectionRetention)
        for record in state.rejected.values where record.at >= cutoff {
            keep.insert(record.version)
        }
        return keep
    }

    /// Drops rejection records older than seven days (§4.8).
    public func pruneExpiredRejections() {
        let cutoff = clock().addingTimeInterval(-Self.rejectionRetention)
        let stale = state.rejected.filter { $0.value.at < cutoff }
        guard !stale.isEmpty else { return }
        for key in stale.keys {
            state.rejected.removeValue(forKey: key)
        }
        logger.notice("Dropped \(stale.count, .public) expired image rejections (seven-day retention)")
        save()
    }

    // MARK: - Apply bookkeeping

    private func setPhase(_ phase: ImageUpdatePhase) {
        state.phase = phase
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(phase)))
    }

    private func noteInstalled(_ version: ImageCore.ImageVersion) {
        logger.notice("IMAGE_MIGRATION_END \(version.description, .public) installed")
        state.phase = .idle
        state.lastResult = .installed(version)
        state.lastAutomaticApplyAt = clock()
        state.candidate = nil
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    private func noteApplyFailed(
        _ version: ImageCore.ImageVersion, error: any Error, restoreFailure: Bool = false
    ) {
        // The supervisor already restored the previous image; record the
        // rejection (§4.8). A failed *restore* leaves Android on the abandoned
        // image, so the rollback target is not rejected.
        logger.notice(
            "IMAGE_MIGRATION_END \(version.description, .public) rejected: \(error.localizedDescription, .public)")
        state.phase = .failed(state.candidate, reason: error.localizedDescription, retryAt: nil)
        if !restoreFailure {
            state.lastResult = .rejected(version, reason: .migrationFailed)
            state.rejected[version.description] = RejectedImage(
                version: version, at: clock(), reason: .migrationFailed,
                detail: error.localizedDescription
            )
        }
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    // MARK: - Checks, downloads, installs (#88, runtime-maintenance.md §4.2–§4.5)

    /// A feed check starts. `checking` is transient: the persisted phase stays
    /// the previous one so a restart runs the check again (§4.3).
    public func beginCheck() {
        publish(.imageUpdateChanged(.checking))
    }

    /// Records a successful check: daily schedule, cleared backoff, and the
    /// phase of §4.3 (`available` with a candidate, `idle` without). A `ready`
    /// image is replaced only by a newer candidate; an equal one is kept.
    public func noteCheckResult(
        candidate: ImageCandidate?, requiresNewerAPKRun: ImageCore.ImageVersion?
    ) {
        state.lastCheckAt = clock()
        state.nextCheckAt = clock().addingTimeInterval(24 * 3600)
        state.checkFailures = 0
        state.requiresNewerAPKRun = requiresNewerAPKRun
        if let candidate {
            state.candidate = candidate
            if case .ready(let ready) = state.phase, candidate.version <= ready {
                // The ready image stays unless the feed offers something newer.
            } else {
                state.phase = .available(candidate)
            }
        } else if case .ready = state.phase {
            // A ready image is unaffected by an empty check.
        } else {
            state.phase = .idle
            state.candidate = nil
        }
        logger.notice(
            "IMAGE_CHECK_END candidate \(state.candidate?.version.description ?? "-", .public)")
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    /// Records a failed check: the 1 h / 6 h backoff, then the daily
    /// schedule (§4.2).
    public func noteCheckFailed(reason: String) {
        let failures = (state.checkFailures ?? 0) + 1
        state.checkFailures = failures
        state.lastCheckAt = clock()
        let delay: TimeInterval =
            switch failures {
            case 1: 3600
            case 2: 6 * 3600
            default: 24 * 3600
            }
        state.nextCheckAt = clock().addingTimeInterval(delay)
        state.phase = .failed(state.candidate, reason: reason, retryAt: state.nextCheckAt)
        logger.notice("IMAGE_CHECK_END failed: \(reason, .public)")
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    /// A candidate's download starts; the phase is persisted so a restart can
    /// resume the partial file (§4.3).
    public func noteDownloadStarted(_ candidate: ImageCandidate) {
        state.phase = .downloading(candidate, progress: 0)
        logger.notice(
            "IMAGE_DOWNLOAD_START \(candidate.version.description, .public) from \(candidate.archiveLocation ?? "-", .public)"
        )
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    /// Progress ticks of a running download; published, not persisted.
    public func noteDownloadProgress(_ candidate: ImageCandidate, fraction: Double) {
        publish(.imageUpdateChanged(.downloading(WireImageCandidate(candidate), progress: fraction)))
    }

    /// Records a failed download: 15 minutes, 1 hour, then 6 hours; the
    /// partial file stays for resume (§4.3–§4.4).
    public func noteDownloadFailed(_ candidate: ImageCandidate, reason: String) {
        let failures = (state.downloadFailures ?? 0) + 1
        state.downloadFailures = failures
        let delay: TimeInterval =
            switch failures {
            case 1: 15 * 60
            case 2: 3600
            default: 6 * 3600
            }
        state.phase = .failed(candidate, reason: reason, retryAt: clock().addingTimeInterval(delay))
        logger.notice("IMAGE_DOWNLOAD_END failed: \(reason, .public)")
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    /// Records a failed install: one retry downloads the archive again; after
    /// a second failure nothing retries until the feed changes (§4.3).
    public func noteInstallFailed(_ candidate: ImageCandidate, reason: String) {
        let failures = (state.installFailures ?? 0) + 1
        state.installFailures = failures
        if failures < 2 {
            state.phase = .available(candidate)
        } else {
            state.phase = .failed(candidate, reason: reason, retryAt: nil)
        }
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
    }

    /// True when 24 hours passed since the last automatic apply attempt (A7).
    public func automaticApplyWindowOpen() -> Bool {
        guard let last = state.lastAutomaticApplyAt else { return true }
        return clock().timeIntervalSince(last) >= 24 * 3600
    }

    /// Records that an automatic apply attempt started (A7).
    public func noteAutomaticApplyAttempt() {
        state.lastAutomaticApplyAt = clock()
        save()
    }

    /// The version the user was last asked about (§4.6 ask-mode reminders).
    public func noteNotified(_ version: ImageCore.ImageVersion) {
        if !state.notifiedVersions.contains(version.description) {
            state.notifiedVersions.append(version.description)
            save()
        }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try FileManager.default.createDirectory(
                at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: stateFile, options: .atomic)
        } catch {
            logger.error("Could not write the image update state: \(error.localizedDescription, .public)")
        }
    }

    private static func load(from url: URL) throws -> ImageUpdateState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ImageUpdateState.self, from: Data(contentsOf: url))
    }
}

extension ImageUpdatePhase {
    /// A short label for logging and `apkrun image`.
    public var phaseDescription: String {
        switch self {
        case .idle: "idle"
        case .checking: "checking"
        case .available(let candidate): "available(\(candidate.version))"
        case .downloading(let candidate, let progress):
            "downloading(\(candidate.version),\(Int(progress * 100))%)"
        case .installing(let candidate, let fraction):
            "installing(\(candidate.version),\(Int(fraction * 100))%)"
        case .ready(let version): "ready(\(version))"
        case .applying(let from, let to): "applying(\(from)->\(to))"
        case .failed(let candidate, let reason, _): "failed(\(candidate?.version.description ?? "-"),\(reason))"
        }
    }
}
