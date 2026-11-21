import DiagnosticsCore
import Foundation

/// `Runtime/instance/recovery-points/<timestamp>-<imageVersion>/` (android-image.md §12.2).
public struct RecoveryPoint: Codable, Equatable, Sendable {
    /// The directory name: `<timestamp>-<imageVersion>`.
    public var name: String
    /// The image the point was taken under; `nil` for a `failed-*` dump.
    public var imageVersion: ImageVersion?
    /// When the point was taken.
    public var createdAt: Date
    /// Whether this is a `failed-<ts>` diagnostics directory (§12.3 step 6b).
    public var isFailedDump: Bool
}

/// The ImageCore data steps of a migration A → B (android-image.md §12.1–12.3): the
/// compatibility check, the recovery point, and the `instance.json` `migration`
/// record. The boot and the health check belong to RuntimeCore.
public actor ImageMigrationService {
    private let store: InstanceStore
    private let logger: APKLogger

    /// Creates the service over an `InstanceStore`.
    public init(store: InstanceStore, diagnostics: DiagnosticsContext) {
        self.store = store
        logger = APKLogger(category: ImageLogCategory.instance, sink: diagnostics.logSink)
    }

    /// §12.1: whether `to` may replace `from` on this host. `hostRuntimeVersion` is the
    /// running APKRun version (`MAJOR.MINOR.PATCH`); `hostProtocol` is the inclusive
    /// guest-protocol range the host speaks.
    public func checkAllowed(
        from source: InstalledImage,
        to target: InstalledImage,
        hostRuntimeVersion: String,
        hostProtocol: (min: Int, max: Int),
        userdataSchema: Int
    ) throws(ImageFailure) {
        if target.version < source.version {
            throw .downgradeRejected(from: source.version.description, to: target.version.description)
        }
        if compareVersions(hostRuntimeVersion, target.manifest.requirements.minimumRuntimeVersion) < 0 {
            throw .incompatibleRuntime(
                minimum: target.manifest.requirements.minimumRuntimeVersion,
                found: hostRuntimeVersion
            )
        }
        let wanted = target.manifest.requirements.guestProtocol
        if wanted.max < hostProtocol.min || wanted.min > hostProtocol.max {
            throw .incompatibleProtocol(
                minimum: wanted.min, maximum: wanted.max,
                hostMinimum: hostProtocol.min, hostMaximum: hostProtocol.max
            )
        }
        if !target.manifest.userdata.upgradableFrom.contains(userdataSchema) {
            throw .userdataSchemaUnsupported(
                schema: userdataSchema, supported: target.manifest.userdata.upgradableFrom
            )
        }
        let minimum = target.manifest.compatibility.upgradeFrom.minimumImageVersion
        if compareVersions(source.version.shortForm, minimum) < 0 {
            throw .migrationSourceTooOld(source: source.version.description, minimum: minimum)
        }
    }

    /// §12.3 steps 2–3: recovery point R, then `migration` ← (A, B), `previous` → A,
    /// `current` → B, `imageVersion` ← B. The VM must be stopped. Returns R's name.
    @discardableResult
    public func beginMigration(
        from source: InstalledImage,
        to target: InstalledImage,
        images: ImageStore
    ) async throws(ImageFailure) -> String {
        let point = try await store.createRecoveryPoint(image: source)
        try await store.recordMigration(from: source.version, to: target.version)
        try await images.setCurrent(target.version)
        try await store.rewriteImageVersion(target.version)
        logger.notice(
            "Recorded migration \(source.version.description, .public) → \(target.version.description, .public)"
        )
        return point.lastPathComponent
    }

    /// §12.3 step 6a: the migration record goes away and every recovery point but the
    /// newest is pruned.
    public func completeMigration() async throws(ImageFailure) {
        try await store.clearMigration()
        try await store.pruneRecoveryPoints(keepingNewest: true)
    }

    /// §12.3 step 6b: the failed disks move to `recovery-points/failed-<ts>/`, R is
    /// restored, `current` → A, and `instance.json` gets a new `userdataGeneration`
    /// and no `migration`.
    public func abortMigration(restoredTo image: InstalledImage) async throws(ImageFailure) {
        try await store.moveInstanceAside(tag: "failed")
        try await store.restoreLatestRecoveryPoint(image: image)
        logger.notice("Restored the recovery point of \(image.version.description, .public)")
    }

    /// Whether `instance.json` carries a `migration` record found at startup; the
    /// caller then runs `abortMigration` (§12.3 crash safety → `migrationInterrupted`).
    public func hasInterruptedMigration(image: InstalledImage) async throws(ImageFailure) -> Bool {
        try await store.load(image: image)?.migration != nil
    }
}

/// Numeric compare of `MAJOR.MINOR.PATCH` (or `YYYY.MM.N`) strings; missing parts are 0.
func compareVersions(_ lhs: String, _ rhs: String) -> Int {
    func parts(_ string: String) -> [Int] {
        string.split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = parts(lhs)
    let b = parts(rhs)
    for index in 0..<max(a.count, b.count) {
        let x = index < a.count ? a[index] : 0
        let y = index < b.count ? b[index] : 0
        if x != y { return x < y ? -1 : 1 }
    }
    return 0
}
