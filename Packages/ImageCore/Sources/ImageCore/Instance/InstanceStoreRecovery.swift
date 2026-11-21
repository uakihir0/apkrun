import DiagnosticsCore
import Foundation

extension InstanceStore {
    /// Reads `instance.json` without the disk checks of `load(image:)`: needed when the
    /// instance's image is not the one being looked at (migration records).
    func loadConfiguration() throws(ImageFailure) -> InstanceConfiguration? {
        guard FileManager.default.fileExists(atPath: paths.instanceInfoFile.path) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(
                InstanceConfiguration.self,
                from: Data(contentsOf: paths.instanceInfoFile)
            )
        } catch {
            throw .instanceCorrupt(reason: "instance.json does not decode")
        }
    }

    private func updateConfiguration(
        _ change: (inout InstanceConfiguration) -> Void
    ) throws(ImageFailure) {
        guard var configuration = try loadConfiguration() else {
            throw .instanceMissing
        }
        change(&configuration)
        try write(configuration)
    }

    /// §12.3 step 3a: `migration` ← (A, B), written before anything else changes.
    func recordMigration(from source: ImageVersion, to target: ImageVersion) throws(ImageFailure) {
        try updateConfiguration {
            $0.migration = InstanceConfiguration.Migration(from: source, to: target)
        }
    }

    /// §12.3 step 3b: `imageVersion` ← B after `current` moved.
    func rewriteImageVersion(_ version: ImageVersion) throws(ImageFailure) {
        try updateConfiguration { $0.imageVersion = version }
    }

    /// §12.3 step 6a: the migration record is removed.
    func clearMigration() throws(ImageFailure) {
        try updateConfiguration { $0.migration = nil }
    }

    /// Every recovery point and `failed-*` dump under `Runtime/instance/recovery-points/`,
    /// newest first.
    public func listRecoveryPoints() throws(ImageFailure) -> [RecoveryPoint] {
        let directory = paths.recoveryPointsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var points: [RecoveryPoint] = []
        for name in names {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            let created =
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate]
                as? Date ?? Date.distantPast
            if name.hasPrefix("failed-") {
                points.append(
                    RecoveryPoint(
                        name: name,
                        imageVersion: nil,
                        createdAt: created, isFailedDump: true
                    )
                )
            } else if let versionStart = name.range(
                of: #"[0-9]{4}\.[0-9]{2}\.[0-9]+-"#, options: .regularExpression
            )?.lowerBound,
                let version = ImageVersion(String(name[versionStart...]))
            {
                points.append(
                    RecoveryPoint(
                        name: name, imageVersion: version, createdAt: created,
                        isFailedDump: false
                    )
                )
            }
        }
        return points.sorted { $0.createdAt > $1.createdAt }
    }

    /// Restores the newest recovery point (R): clone `userdata.img` and `instance.json`
    /// back, then give the instance a new `userdataGeneration` and no `migration`
    /// (§12.3 step 6b, §12.2).
    public func restoreLatestRecoveryPoint(image: InstalledImage) throws(ImageFailure) {
        guard let point = try listRecoveryPoints().first(where: { !$0.isFailedDump }) else {
            throw .instanceMissing
        }
        try restoreRecoveryPoint(point, image: image)
    }

    /// Restores one named recovery point.
    public func restoreRecoveryPoint(
        _ point: RecoveryPoint, image: InstalledImage
    ) throws(ImageFailure) {
        let source = paths.recoveryPointsDirectory.appendingPathComponent(
            point.name, isDirectory: true
        )
        for (file, destination) in [
            ("userdata.img", paths.userDataDiskFile),
            ("instance.json", paths.instanceInfoFile),
        ] {
            let origin = source.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: origin.path) else {
                throw .instanceCorrupt(reason: "recovery point \(point.name) lacks \(file)")
            }
            do {
                try FileCloner.clone(origin, destination)
            } catch {
                throw .cloneFailed(
                    underlying: UnderlyingError(
                        domain: "NSCocoaErrorDomain", code: (error as NSError).code
                    )
                )
            }
        }
        try updateConfiguration {
            $0.migration = nil
            $0.userdataGeneration = UUID()
            $0.imageVersion = image.version
        }
    }

    /// §12.3 step 6b: the failed disks move to `recovery-points/failed-<ts>/` for
    /// diagnostics. `instance.json` moves last so an interruption leaves a complete
    /// dump or none.
    func moveInstanceAside(tag: String) throws(ImageFailure) {
        let name = "failed-\(Self.recoveryTimestamp(Date()))-\(tag)"
        let destination = paths.recoveryPointsDirectory.appendingPathComponent(
            name, isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw .cloneFailed(
                underlying: UnderlyingError(
                    domain: "NSCocoaErrorDomain", code: (error as NSError).code
                )
            )
        }
        let entries =
            (try? FileManager.default.contentsOfDirectory(atPath: paths.instanceDirectory.path))
            ?? []
        for entry in entries.sorted(by: { ($0 == "instance.json") ? false : ($1 == "instance.json") })
        where entry != "recovery-points" {
            let source = paths.instanceDirectory.appendingPathComponent(entry)
            let target = destination.appendingPathComponent(entry)
            do {
                try FileManager.default.moveItem(at: source, to: target)
            } catch {
                throw .cloneFailed(
                    underlying: UnderlyingError(
                        domain: "NSCocoaErrorDomain", code: (error as NSError).code
                    )
                )
            }
        }
    }

    /// §12.2: after a successful migration only the newest recovery point stays.
    /// `failed-*` dumps are not touched here (§12.3 keeps them 7 days; GC handles age).
    func pruneRecoveryPoints(keepingNewest: Bool) throws(ImageFailure) {
        let points = try listRecoveryPoints().filter { !$0.isFailedDump }
        for (index, point) in points.enumerated() {
            if keepingNewest && index == 0 { continue }
            try? FileManager.default.removeItem(
                at: paths.recoveryPointsDirectory.appendingPathComponent(point.name)
            )
        }
    }

    /// Deletes `failed-*` dumps older than `days` (§12.3 keeps them for diagnostics).
    public func pruneFailedDumps(olderThan days: Int = 7) throws(ImageFailure) {
        let cutoff = Date().addingTimeInterval(-TimeInterval(days * 86_400))
        for point in try listRecoveryPoints() where point.isFailedDump && point.createdAt < cutoff {
            try? FileManager.default.removeItem(
                at: paths.recoveryPointsDirectory.appendingPathComponent(point.name)
            )
        }
    }

    /// Deletes one named recovery point (`apkrun image recovery-points delete`).
    public func deleteRecoveryPoint(named name: String) throws(ImageFailure) {
        let url = paths.recoveryPointsDirectory.appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path), !name.contains("/"),
            !name.contains("..")
        else {
            throw .instanceCorrupt(reason: "no recovery point \(name)")
        }
        try? FileManager.default.removeItem(at: url)
    }
    /// The instance's recorded userdata schema (android-image.md §12.1), when a
    /// configuration exists.
    public func userdataSchemaVersion() -> Int? {
        (try? loadConfiguration())?.userdataSchemaVersion
    }
}
