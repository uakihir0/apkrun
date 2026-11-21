import Foundation

/// The outcome of `SchemaMigrator.migrate` (runtime-maintenance.md §5).
public enum SchemaMigrationOutcome: Equatable, Sendable {
    /// The file already carries the current schema; nothing was written.
    case unchanged(version: Int)

    /// The file was migrated `from → to`; the original bytes were kept next to
    /// it as `<name>.v<from>.json`.
    case migrated(from: Int, to: Int)
}

/// Migrates the on-disk JSON files owned by a component between schema
/// versions (runtime-maintenance.md §5).
///
/// Every JSON file carries an integer `schemaVersion`; JSONL files carry `"v"`
/// on every line. A build knows the current version of each file
/// (`DataSchemas.current`) and has a migration step `n → n+1` for every older
/// version in the compatibility window. On migration the original bytes are
/// kept as `<name>.v<old>.json` next to the file, and the result is written
/// atomically.
public struct SchemaMigrator: Sendable {
    /// One migration step `n → n+1`: transforms the decoded object of a single
    /// file (or one JSONL line). Throwing aborts the migration with
    /// `MaintenanceFailure.schemaMigrationFailed` and leaves the file untouched.
    public typealias MigrationStep = @Sendable ([String: Any]) throws -> [String: Any]

    /// Steps per file, indexed by the version they migrate FROM: `steps[file][n]`
    /// transforms a version-`n` document into version `n+1`.
    private let steps: [String: [Int: MigrationStep]]

    /// The current schema version per file.
    private let current: [String: Int]

    /// Creates a migrator; the default maps come from `DataSchemas.current`.
    public init(
        steps: [String: [Int: MigrationStep]] = [:],
        current: [String: Int] = DataSchemas.current
    ) {
        self.steps = steps
        self.current = current
    }

    /// Migrates `url` in place when its schema is older than the build's.
    ///
    /// - Parameters:
    ///   - url: the file to migrate.
    ///   - file: the file's registry name in `DataSchemas.current` (for example
    ///     `"settings.json"` or `"Updates/history.jsonl"`). A name ending in
    ///     `.jsonl` is migrated line by line using each line's `"v"`.
    public func migrate(url: URL, file: String) throws -> SchemaMigrationOutcome {
        guard let supported = current[file] else {
            throw MaintenanceFailure.schemaMigrationFailed(
                file: file, from: 0, to: 0, detail: "file is not in the schema registry"
            )
        }
        let isJSONL = file.hasSuffix(".jsonl")
        let data = try Data(contentsOf: url)

        if isJSONL {
            return try migrateJSONL(data: data, url: url, file: file, supported: supported)
        }
        let object = try decodeObject(data, file: file, version: 0)
        guard let version = object["schemaVersion"] as? Int else {
            throw MaintenanceFailure.schemaMigrationFailed(
                file: file, from: 0, to: 0, detail: "missing integer schemaVersion"
            )
        }
        if version > supported {
            throw MaintenanceFailure.dataCreatedByNewerVersion(
                file: file, schema: version, supported: supported
            )
        }
        if version == supported {
            return .unchanged(version: version)
        }
        var migrated = object
        for version in version..<supported {
            guard let step = steps[file]?[version] else {
                throw MaintenanceFailure.schemaMigrationFailed(
                    file: file, from: version, to: version + 1,
                    detail: "no migration step for this file"
                )
            }
            do {
                migrated = try step(migrated)
            } catch {
                throw MaintenanceFailure.schemaMigrationFailed(
                    file: file, from: version, to: version + 1,
                    detail: String(describing: error)
                )
            }
            migrated["schemaVersion"] = version + 1
        }
        try writeMigrated(migrated, data: data, url: url, file: file, from: version)
        return .migrated(from: version, to: supported)
    }

    private func migrateJSONL(
        data: Data, url: URL, file: String, supported: Int
    ) throws -> SchemaMigrationOutcome {
        var lines = data.split(separator: 0x0A).map { Data($0) }
        lines.removeAll { $0.allSatisfy { $0 == 0x20 || $0 == 0x0D } }
        var oldest = Int.max
        var decoded: [[String: Any]] = []
        for line in lines {
            let object = try decodeObject(line, file: file, version: 0)
            guard let version = object["v"] as? Int else {
                throw MaintenanceFailure.schemaMigrationFailed(
                    file: file, from: 0, to: 0, detail: "a JSONL line has no integer \"v\""
                )
            }
            if version > supported {
                throw MaintenanceFailure.dataCreatedByNewerVersion(
                    file: file, schema: version, supported: supported
                )
            }
            oldest = min(oldest, version)
            decoded.append(object)
        }
        if decoded.isEmpty || oldest == supported {
            return .unchanged(version: decoded.isEmpty ? supported : oldest)
        }
        var migratedLines: [Data] = []
        for object in decoded {
            var migrated = object
            var version = migrated["v"] as? Int ?? supported
            while version < supported {
                guard let step = steps[file]?[version] else {
                    throw MaintenanceFailure.schemaMigrationFailed(
                        file: file, from: version, to: version + 1,
                        detail: "no migration step for this file"
                    )
                }
                do {
                    migrated = try step(migrated)
                } catch {
                    throw MaintenanceFailure.schemaMigrationFailed(
                        file: file, from: version, to: version + 1,
                        detail: String(describing: error)
                    )
                }
                version += 1
                migrated["v"] = version
            }
            migratedLines.append(try encode(migrated, file: file))
        }
        var output = Data()
        for (index, line) in migratedLines.enumerated() {
            output.append(line)
            if index < migratedLines.count - 1 { output.append(0x0A) }
        }
        output.append(0x0A)
        try backup(data: data, url: url, file: file, from: oldest)
        try output.write(to: url, options: .atomic)
        return .migrated(from: oldest, to: supported)
    }

    private func writeMigrated(
        _ object: [String: Any], data: Data, url: URL, file: String, from: Int
    ) throws {
        let encoded = try encode(object, file: file)
        try backup(data: data, url: url, file: file, from: from)
        try encoded.write(to: url, options: .atomic)
    }

    /// Keeps the original bytes as `<name>.v<version>.json` beside the file:
    /// one backup per old version, deleted 90 days after the migration (§5).
    private func backup(data: Data, url: URL, file: String, from: Int) throws {
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent).v\(from).\(url.pathExtension)"
            )
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try data.write(to: backupURL)
    }

    private func decodeObject(_ data: Data, file: String, version: Int) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MaintenanceFailure.schemaMigrationFailed(
                    file: file, from: version, to: version, detail: "not a JSON object"
                )
            }
            return object
        } catch let failure as MaintenanceFailure {
            throw failure
        } catch {
            throw MaintenanceFailure.schemaMigrationFailed(
                file: file, from: version, to: version, detail: String(describing: error)
            )
        }
    }

    private func encode(_ object: [String: Any], file: String) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MaintenanceFailure.schemaMigrationFailed(
                file: file, from: 0, to: 0, detail: "migration produced non-JSON output"
            )
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
