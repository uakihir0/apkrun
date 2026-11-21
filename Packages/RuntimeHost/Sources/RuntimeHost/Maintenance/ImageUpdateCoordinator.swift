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
                await self.noteApplyFailed(version, error: failure)
                throw failure
            } catch {
                let failure = ImageFailure.imageUpdateBusy(detail: "\(error)")
                await self.noteApplyFailed(version, error: failure)
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

    private func noteApplyFailed(_ version: ImageCore.ImageVersion, error: any Error) {
        // The supervisor already restored the previous image; record the
        // rejection (§4.8).
        logger.notice(
            "IMAGE_MIGRATION_END \(version.description, .public) rejected: \(error.localizedDescription, .public)")
        state.phase = .failed(state.candidate, reason: error.localizedDescription, retryAt: nil)
        state.lastResult = .rejected(version, reason: .migrationFailed)
        state.rejected[version.description] = RejectedImage(
            version: version, at: clock(), reason: .migrationFailed,
            detail: error.localizedDescription
        )
        save()
        publish(.imageUpdateChanged(WireImageUpdatePhase(state.phase)))
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
