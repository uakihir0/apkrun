import DiagnosticsCore
import Foundation
import GuestProtocol
import IOKit.pwr_mgt
import ImageCore
import RuntimeAPI
import RuntimeCore

/// The Android image update driver (runtime-maintenance.md §4, android-image.md §12.3).
extension RuntimeHost {
    /// The image update coordinator, built on first use. Its `migrate` hook is
    /// ``migrateImage(to:operationID:)`` below, so the coordinator stays the
    /// only writer of `Images/update-state.json`.
    var imageUpdateCoordinator: ImageUpdateCoordinator {
        if let _imageUpdateCoordinator { return _imageUpdateCoordinator }
        let coordinator = ImageUpdateCoordinator(
            paths: paths,
            diagnostics: diagnostics ?? .live(paths: paths),
            publish: { [eventHub] event in
                eventHub.publishMaintenanceEvent(event)
            },
            migrate: { [weak self] version, operationID, restoring in
                guard let self else {
                    throw ImageFailure.noCurrentImage
                }
                do {
                    try await self.migrateImage(to: version, operationID: operationID, restoring: restoring)
                } catch let failure as ImageFailure {
                    throw failure
                } catch {
                    throw ImageFailure.migrationHealthFailed(report: "\(error)")
                }
            }
        )
        _imageUpdateCoordinator = coordinator
        return coordinator
    }

    /// Settles a persisted `applying` phase against the image that is current
    /// after this daemon's start (runtime-maintenance.md §4.3). Called from the
    /// startup sequence once `imageStore` and `instanceStore` are known.
    func reconcileImageUpdate() async {
        var current = try? await imageStore?.current().version
        // §12.3 crash safety: a `migration` record left in instance.json means
        // the migration never completed — restore the recovery point instead of
        // recording the half-applied image as installed.
        if let images = imageStore, let instanceStore, let diagnostics,
            let installed = try? await images.current(),
            (try? await ImageMigrationService(store: instanceStore, diagnostics: diagnostics)
                .hasInterruptedMigration(image: installed)) == true,
            let previous = try? await images.previous()
        {
            let migration = ImageMigrationService(store: instanceStore, diagnostics: diagnostics)
            try? await migration.abortMigration(restoredTo: previous)
            image = try? await images.installed(previous.version)
            current = previous.version
        }
        await imageUpdateCoordinator.reconcile(currentImage: current ?? nil)
    }

    /// Migrates Android to the already-installed image `version`
    /// (android-image.md §12.3): ends sessions, stops the VM, runs the
    /// ImageCore data steps, boots B and health-checks it. On failure the
    /// previous image is restored and the caller records the rejection (§4.8).
    func migrateImage(
        to version: ImageCore.ImageVersion,
        operationID: UUID,
        restoring: Bool = false
    ) async throws(ImageFailure) {
        guard let images = imageStore, let instanceStore else {
            throw .noCurrentImage
        }
        guard let diagnostics else {
            throw .noCurrentImage
        }
        let from = try await images.current()
        guard from.version != version else {
            return
        }
        imageMigrating = true
        defer { imageMigrating = false }
        do {
            try beginLifecycleOperation()
        } catch {
            throw .imageUpdateBusy(detail: "the runtime is not ready: \(error)")
        }
        defer { finishLifecycleOperation() }
        let activity = await updateIdleController.assertActivity(.migration)
        defer { activity.release() }
        let assertion = IOPMAssertion.begin(reason: "Updating Android")
        defer { assertion.end() }

        let migration = ImageMigrationService(store: instanceStore, diagnostics: diagnostics)
        let target = try await images.installed(version)
        if !restoring {
            // Preconditions first: a refused candidate leaves Android running.
            let userdataSchema = await instanceStore.userdataSchemaVersion() ?? 0
            try await migration.checkAllowed(
                from: from,
                to: target,
                hostRuntimeVersion: buildIdentity.marketingVersion,
                hostProtocol: (
                    min: Int(ProtocolVersion.supportedMajors.lowerBound),
                    max: Int(ProtocolVersion.supportedMajors.upperBound)
                ),
                userdataSchema: userdataSchema
            )
        }

        // §12.3 precondition: in-flight package transactions finish first, then
        // sessions end (`ended(.runtimeUpdating)`) and the VM stops gracefully.
        await waitForPackageMutations()
        for packageID in await maintenanceSessionPackageIDs() {
            await endSessionForImageUpdate(packageID: packageID)
        }
        if let supervisor {
            await supervisor.stop(reason: .migration)
            dropSupervisor()
        }

        if restoring {
            // §4.8: back to A restores its recovery point — no compatibility
            // check and no new recovery point.
            try await migration.abortMigration(restoredTo: target)
        } else {
            // Steps 2–3: recovery point, `migration` marker, `current` → B.
            try await migration.beginMigration(from: from, to: target, images: images)
        }
        image = target

        // Step 4: boot B with the existing userdata. `bootPurpose` rides the
        // runtime status so clients can show "Updating Android…".
        if let wireFrom = RuntimeAPI.ImageVersion(from.version.description),
            let wireTo = RuntimeAPI.ImageVersion(version.description)
        {
            bootPurpose = .imageUpdate(from: wireFrom, to: wireTo)
        }
        defer { bootPurpose = nil }
        do {
            let supervisor = try supervisorInstance()
            try await Self.withTimeout(seconds: 15 * 60) {
                try await supervisor.ensureReady(.automatic)
            }
            // Step 5: the health check — every managed package present at its
            // recorded version.
            try await imageHealthCheck()
        } catch let failure as ImageFailure {
            try await abortImageMigration(migration, to: from, report: failure.code)
            throw failure
        } catch {
            try await abortImageMigration(migration, to: from, report: "\(error)")
            throw .migrationHealthFailed(report: "\(error)")
        }
        // 6a: installed(B) — clear `migration`, keep only the newest point, GC images.
        try await migration.completeMigration()
        await dropRuntimeAttachedServices()
        try? await images.garbageCollect(retaining: await imageUpdateCoordinator.gcRetainSet())
        logger?.notice("Migrated Android to image \(version.description, .public)")
    }

    /// §12.3 step 6b: stop B, move the failed disks aside, restore the recovery
    /// point, and put `current` back on A.
    private func abortImageMigration(
        _ migration: ImageMigrationService,
        to restored: InstalledImage,
        report: String
    ) async throws(ImageFailure) {
        if let supervisor {
            await supervisor.stop(reason: .migration)
            dropSupervisor()
        }
        try await migration.abortMigration(restoredTo: restored)
        image = try? await imageStore?.installed(restored.version)
        await dropRuntimeAttachedServices()
        logger?.error("Image migration failed (\(report, .public)); restored \(restored.version.description, .public)")
    }

    /// §12.3 step 5: after `ensureReady` (boot_completed plus the Guest and
    /// Store Agent handshakes it already covers), every managed package must be
    /// present in Android's inventory.
    private func imageHealthCheck() async throws(ImageFailure) {
        let service = packageQueryServiceInstance()
        do {
            try await attachPackageQueriesIfRuntimeIsReady(to: service)
        } catch {
            throw .migrationHealthFailed(report: "package queries unavailable: \(error)")
        }
        do {
            let result = try await service.listPackages(RuntimeListPackagesRequest(filter: .all))
            guard result.source != .noAndroidInventory else {
                throw ImageFailure.migrationHealthFailed(report: "android inventory unavailable")
            }
            let broken = result.packages.filter {
                $0.managed && $0.state != .installed && $0.state != .uninstalledKeepingData
            }
            guard broken.isEmpty else {
                throw ImageFailure.migrationHealthFailed(
                    report: "missing packages: \(broken.map(\.packageID.rawValue).joined(separator: ","))"
                )
            }
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw .migrationHealthFailed(report: "\(error)")
        }
    }

    /// Runs `body` with a whole-timeout deadline, throwing `.migrationHealthFailed`
    /// when the deadline wins. Sleep suspends with the machine; the 15-minute
    /// first-boot budget is wall-clock, which is close enough (R-22).
    private static func withTimeout<T: Sendable>(
        seconds: UInt64,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ImageFailure.migrationHealthFailed(report: "first boot timed out")
            }
            guard let value = try await group.next() else {
                throw ImageFailure.migrationHealthFailed(report: "first boot timed out")
            }
            group.cancelAll()
            return value
        }
    }

    /// Ends one session for an image migration (`ended(.runtimeUpdating)`).
    private func endSessionForImageUpdate(packageID: RuntimePackageID) async {
        guard let service = sessionServiceForIntegrations() else { return }
        await service.endSessionForUpdate(packageID: packageID, reason: .runtimeUpdating)
    }

    /// The `imageStatus` wire reply (`apkrun image list`, Settings → Storage).
    func imageStatus() async -> WireImageStatus {
        let snapshot = await imageUpdateCoordinator.stateSnapshot()
        var rejected: [WireRejectedImage] = []
        for record in snapshot.rejected.values.sorted(by: { $0.at > $1.at }) {
            rejected.append(
                WireRejectedImage(
                    version: record.version.description,
                    at: record.at,
                    reason: record.reason.rawValue,
                    detail: record.detail
                )
            )
        }
        var recovery: [WireRecoveryPoint] = []
        if let instanceStore {
            for point in (try? await instanceStore.listRecoveryPoints()) ?? [] {
                recovery.append(
                    WireRecoveryPoint(
                        name: point.name,
                        imageVersion: point.imageVersion?.description,
                        createdAt: point.createdAt,
                        isFailedDump: point.isFailedDump
                    )
                )
            }
        }
        return WireImageStatus(
            phase: WireImageUpdatePhase(snapshot.phase),
            current: (try? await imageStore?.current().version.description) ?? nil,
            previous: try? await imageStore?.previous()?.version.description,
            rejected: rejected,
            lastResult: snapshot.lastResult.map(\.resultDescription),
            lastCheckAt: snapshot.lastCheckAt,
            nextCheckAt: snapshot.nextCheckAt,
            recoveryPoints: recovery
        )
    }

    /// Deletes one recovery point (`apkrun image recovery-points delete`).
    func deleteImageRecoveryPoint(named name: String) async throws(ImageFailure) {
        guard let instanceStore else {
            throw .instanceMissing
        }
        try await instanceStore.deleteRecoveryPoint(named: name)
    }
}

/// A PreventUserIdleSystemSleep assertion held while a migration runs
/// (runtime-maintenance.md §4.8). Failing to take it never blocks the migration.
struct IOPMAssertion: Sendable {
    private let id: IOPMAssertionID

    /// Takes the assertion; the returned value is a no-op when IOKit refuses.
    static func begin(reason: String) -> IOPMAssertion {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        return IOPMAssertion(id: status == kIOReturnSuccess ? id : 0)
    }

    /// Releases the assertion.
    func end() {
        if id != 0 {
            IOPMAssertionRelease(id)
        }
    }
}

extension WireImageUpdatePhase {
    /// The wire form of an `ImageUpdatePhase` (RuntimeAPI cannot see ImageCore).
    init(_ phase: ImageUpdatePhase) {
        switch phase {
        case .idle: self = .idle
        case .checking: self = .checking
        case .available(let candidate): self = .available(WireImageCandidate(candidate))
        case .downloading(let candidate, let progress):
            self = .downloading(WireImageCandidate(candidate), progress: progress)
        case .installing(let candidate, let fraction):
            self = .installing(WireImageCandidate(candidate), fraction: fraction)
        case .ready(let version): self = .ready(version.description)
        case .applying(let from, let to): self = .applying(from: from.description, to: to.description)
        case .failed(let candidate, let reason, let retryAt):
            self = .failed(candidate.map(WireImageCandidate.init), reason: reason, retryAt: retryAt)
        }
    }
}

extension WireImageCandidate {
    /// The wire form of an `ImageCandidate`.
    init(_ candidate: ImageCandidate) {
        self.init(
            version: candidate.version.description,
            channel: candidate.channel,
            archiveSHA256: candidate.archiveSHA256,
            archiveSize: candidate.archiveSize,
            expandedSize: candidate.expandedSize,
            archiveLocation: candidate.archiveLocation,
            isCritical: candidate.isCritical
        )
    }
}

extension ImageUpdateResult {
    /// The `lastResult` text of `imageStatus`.
    var resultDescription: String {
        switch self {
        case .installed(let version): "installed(\(version))"
        case .rejected(let version, let reason): "rejected(\(version),\(reason.rawValue))"
        }
    }
}

extension RuntimeHost {
    /// `installImage` handler (runtime-maintenance.md §4.7): copies the `.aar`
    /// FileHandle to a temporary file — the user's file is only read, never
    /// moved, deleted, or closed by us — installs it without activating, and
    /// marks the candidate `ready`.
    func installImage(from file: FileHandle) async throws -> ImageCore.ImageVersion {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-image-\(UUID().uuidString).aar")
        FileManager.default.createFile(atPath: staging.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: staging) }
        let out = try FileHandle(forWritingTo: staging)
        do {
            try file.seek(toOffset: 0)
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
                try out.write(contentsOf: chunk)
            }
            try out.synchronize()
        }
        try out.close()
        guard let imageStore else {
            throw ImageFailure.instanceMissing
        }
        let installed = try await imageStore.install(from: .archive(staging), activate: false)
        await imageUpdateCoordinator.noteReady(installed.version)
        return installed.version
    }

    /// Applies the named `ready` image (`apkrun image apply`).
    func applyImage(_ versionText: String) async throws {
        guard let version = ImageCore.ImageVersion(versionText) else {
            throw ImageFailure.imageRejected(version: versionText, reason: "malformedVersion")
        }
        guard let current = image?.version else {
            throw ImageFailure.noCurrentImage
        }
        try await imageUpdateCoordinator.apply(version, from: current)
    }

    /// Goes back to the previous image (`apkrun image rollback`).
    func rollbackImage() async throws -> String {
        guard let imageStore else {
            throw ImageFailure.instanceMissing
        }
        guard let previous = try await imageStore.previous() else {
            throw ImageFailure.imageRejected(version: "previous", reason: "noPreviousImage")
        }
        guard let abandoned = image?.version else {
            throw ImageFailure.noCurrentImage
        }
        guard let instanceStore,
            (try? await instanceStore.listRecoveryPoints())?.isEmpty == false
        else {
            throw ImageFailure.noRecoveryPoint
        }
        try await imageUpdateCoordinator.rollback(to: previous.version, abandoned: abandoned)
        return "Rolled back to \(previous.version)."
    }
}
