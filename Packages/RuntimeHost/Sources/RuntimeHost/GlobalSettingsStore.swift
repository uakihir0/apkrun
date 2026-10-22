import CoreFoundation
import Darwin
import Foundation
import RuntimeAPI

/// Machine-specific upper bounds used to validate settings and resolve values that no longer fit.
public struct GlobalSettingsStoreLimits: Equatable, Sendable {
    /// The largest CPU count available to the Android VM on this Mac.
    public let cpuCount: Int
    /// The largest Android memory size that fits the physical-memory limit.
    public let memoryGiB: Int
    /// The largest userdata size that fits the free-space limit.
    public let userdataGiB: Int
    /// Whether the Mac currently has enough free space for the minimum userdata size and reserve.
    public let canFitMinimumUserdata: Bool
    /// Whether development-only graphics limits are recognized.
    public let isDebugBuild: Bool

    /// Creates explicit bounds, primarily for deterministic tests.
    public init(
        cpuCount: Int,
        memoryGiB: Int,
        userdataGiB: Int,
        canFitMinimumUserdata: Bool? = nil,
        isDebugBuild: Bool
    ) {
        self.cpuCount = max(2, min(8, cpuCount))
        self.memoryGiB = max(3, memoryGiB)
        self.userdataGiB = max(8, min(256, userdataGiB))
        self.canFitMinimumUserdata = canFitMinimumUserdata ?? (userdataGiB >= 8)
        self.isDebugBuild = isDebugBuild
    }

    /// Derives settings bounds from the Mac and the current build configuration.
    public static func current(fileURL: URL) -> Self {
        let cpuCount = min(8, ProcessInfo.processInfo.processorCount)
        let gibibyte = UInt64(1024 * 1024 * 1024)
        let physicalMemoryGiB = Int(ProcessInfo.processInfo.physicalMemory / gibibyte)
        let memoryGiB = max(3, physicalMemoryGiB / 2)
        let fileManager = FileManager.default
        var fileSystemURL = fileURL.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: fileSystemURL.path),
            fileSystemURL.path != fileSystemURL.deletingLastPathComponent().path
        {
            fileSystemURL.deleteLastPathComponent()
        }
        let fileSystemAttributes = try? fileManager.attributesOfFileSystem(forPath: fileSystemURL.path)
        let freeBytes = (fileSystemAttributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let freeGiB = Int(max(0, freeBytes) / Int64(gibibyte))
        let userdataCapacityGiB = freeGiB - 10
        let userdataGiB = min(256, max(8, userdataCapacityGiB))
        #if DEBUG
            let isDebugBuild = true
        #else
            let isDebugBuild = false
        #endif

        return Self(
            cpuCount: cpuCount,
            memoryGiB: memoryGiB,
            userdataGiB: userdataGiB,
            canFitMinimumUserdata: userdataCapacityGiB >= 8,
            isDebugBuild: isDebugBuild
        )
    }
}

/// A non-fatal issue encountered while loading a supported settings file.
public enum GlobalSettingsLoadDiagnostic: Equatable, Sendable {
    /// A stored key is not part of this build's settings schema.
    case unknownKey(String)
    /// A stored value does not match the setting's supported type or range.
    case invalidValue(String)
    /// A malformed file was moved aside and defaults are in use.
    case corruptFile(archiveName: String)
    /// A supported older schema was migrated to the current schema.
    case migrated(fromSchema: Int)
}

/// The result of loading global settings, including diagnostics for data ignored on load.
public struct GlobalSettingsLoadResult: Equatable, Sendable {
    /// A snapshot containing every setting known to this build.
    public let snapshot: ConfigurationSnapshot
    /// Issues that the host can report through DiagnosticsCore.
    public let diagnostics: [GlobalSettingsLoadDiagnostic]

    /// Creates a load result.
    public init(snapshot: ConfigurationSnapshot, diagnostics: [GlobalSettingsLoadDiagnostic]) {
        self.snapshot = snapshot
        self.diagnostics = diagnostics
    }
}

/// The accepted global settings change and the keys that changed in storage.
public struct GlobalSettingsUpdateResult: Equatable, Sendable {
    /// The resolved configuration after the update.
    public let snapshot: ConfigurationSnapshot
    /// Changed dotted keys, sorted for stable event payloads.
    public let changedKeys: [String]

    /// Creates an update result.
    public init(snapshot: ConfigurationSnapshot, changedKeys: [String]) {
        self.snapshot = snapshot
        self.changedKeys = changedKeys
    }
}

/// Errors returned while loading, validating, migrating, or writing global settings.
public enum GlobalSettingsStoreError: Error, Equatable, Sendable {
    /// The settings file was written by a newer APKRun version and must stay read-only.
    case unsupportedSchema(version: Int)
    /// The request names a setting that this build does not recognize.
    case unknownSetting(key: String)
    /// The setting value has an unsupported type or is outside its allowed range.
    case invalidSettingValue(key: String, allowed: String)
    /// The settings file could not be read or atomically replaced.
    case storage(domain: String, code: Int)
}

/// Owns the schema-versioned global `settings.json` file.
///
/// Only explicitly set values are persisted. Defaults are resolved at read time so machine-specific
/// limits can change without rewriting the user's settings.
public actor GlobalSettingsStore {
    /// The schema version written by this build.
    public static let currentSchemaVersion = 2

    private static let sharedFoldersAllowed = "Use apkrun shared-folders."
    private static let migrationBackupRetention: TimeInterval = 90 * 24 * 60 * 60

    private let fileURL: URL
    private let usesCurrentLimits: Bool
    private var limits: GlobalSettingsStoreLimits
    private var hasLoaded = false
    private var unsupportedSchemaVersion: Int?
    private var explicitValues: [String: JSONValue] = [:]
    private var diagnostics: [GlobalSettingsLoadDiagnostic] = []
    private var writeCount = 0

    /// Creates a global settings store at the supplied file URL.
    public init(fileURL: URL, limits: GlobalSettingsStoreLimits? = nil) {
        self.fileURL = fileURL
        self.usesCurrentLimits = limits == nil
        self.limits = limits ?? .current(fileURL: fileURL)
    }

    /// Loads, migrates if necessary, and returns the current settings snapshot.
    public func load() throws -> GlobalSettingsLoadResult {
        try ensureLoaded()
        refreshMachineLimits()
        return GlobalSettingsLoadResult(
            snapshot: makeSnapshot(),
            diagnostics: diagnostics
        )
    }

    /// Returns the current settings snapshot.
    public func snapshot() throws -> ConfigurationSnapshot {
        try ensureLoaded()
        refreshMachineLimits()
        return makeSnapshot()
    }

    /// Applies a validated RFC 7396 merge patch and persists it before returning.
    public func update(_ request: ConfigurationPatch) throws -> GlobalSettingsUpdateResult {
        try ensureLoaded()
        refreshMachineLimits()
        var changes: [String: JSONValue?] = [:]
        try validatePatch(request.patch, at: "", into: &changes)

        var updatedValues = explicitValues
        for key in changes.keys.sorted() {
            guard let value = changes[key] else { continue }
            if let value {
                updatedValues[key] = value
            } else {
                updatedValues.removeValue(forKey: key)
            }
        }

        let changedKeys = Set(explicitValues.keys).union(updatedValues.keys)
            .filter { explicitValues[$0] != updatedValues[$0] }
            .sorted()
        guard !changedKeys.isEmpty else {
            return GlobalSettingsUpdateResult(snapshot: makeSnapshot(), changedKeys: [])
        }

        try Self.writeAtomically(try encodedSettings(updatedValues), to: fileURL)
        writeCount += 1
        explicitValues = updatedValues
        return GlobalSettingsUpdateResult(snapshot: makeSnapshot(), changedKeys: changedKeys)
    }

    /// Number of successful atomic writes performed by this store instance.
    var successfulWriteCount: Int {
        writeCount
    }

    private func ensureLoaded() throws {
        if let unsupportedSchemaVersion {
            throw GlobalSettingsStoreError.unsupportedSchema(version: unsupportedSchemaVersion)
        }
        guard !hasLoaded else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            hasLoaded = true
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw Self.storageError(error)
        }

        let rootValue: JSONValue
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            guard let dictionary = object as? [String: Any],
                let converted = Self.jsonObject(dictionary)
            else {
                try quarantineCorruptFile()
                return
            }
            rootValue = .object(converted)
        } catch {
            if error is GlobalSettingsStoreError {
                throw error
            }
            try quarantineCorruptFile()
            return
        }

        guard case .object(let root) = rootValue,
            case .integer(let schemaNumber)? = root["schemaVersion"],
            let schemaVersion = Int(exactly: schemaNumber)
        else {
            try quarantineCorruptFile()
            return
        }

        guard schemaVersion > 0 else {
            try quarantineCorruptFile()
            return
        }
        guard schemaVersion <= Self.currentSchemaVersion else {
            unsupportedSchemaVersion = schemaVersion
            throw GlobalSettingsStoreError.unsupportedSchema(version: schemaVersion)
        }
        guard schemaVersion == Self.currentSchemaVersion || schemaVersion == 1 else {
            unsupportedSchemaVersion = schemaVersion
            throw GlobalSettingsStoreError.unsupportedSchema(version: schemaVersion)
        }

        var loadedValues: [String: JSONValue] = [:]
        for key in root.keys.filter({ $0 != "schemaVersion" }).sorted() {
            guard let value = root[key] else { continue }
            collectStoredValue(value, at: key, into: &loadedValues)
        }

        if schemaVersion < Self.currentSchemaVersion {
            try preserveMigrationBackup(for: schemaVersion)
            try Self.writeAtomically(try encodedSettings(loadedValues), to: fileURL)
            writeCount += 1
            removeExpiredMigrationBackups()
            diagnostics.append(.migrated(fromSchema: schemaVersion))
        }

        explicitValues = loadedValues
        hasLoaded = true
    }

    private func quarantineCorruptFile() throws {
        let archiveURL = corruptionArchiveURL()
        do {
            try FileManager.default.moveItem(at: fileURL, to: archiveURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: archiveURL.path
            )
        } catch {
            throw Self.storageError(error)
        }
        explicitValues = [:]
        diagnostics.append(.corruptFile(archiveName: archiveURL.lastPathComponent))
        hasLoaded = true
    }

    private func collectStoredValue(
        _ value: JSONValue,
        at key: String,
        into result: inout [String: JSONValue]
    ) {
        if key == "sharedFolders.roots" {
            guard Self.isValidSharedFolderRoots(value) else {
                diagnostics.append(.invalidValue(key))
                return
            }
            result[key] = value
            return
        }

        if let setting = setting(forKey: key) {
            guard Self.isValidStored(value, for: setting) else {
                diagnostics.append(.invalidValue(key))
                return
            }
            result[key] = value
            return
        }

        if hasSettings(withPrefix: key + ".") {
            guard case .object(let children) = value else {
                diagnostics.append(.invalidValue(key))
                return
            }
            for childKey in children.keys.sorted() {
                guard let child = children[childKey] else { continue }
                collectStoredValue(child, at: "\(key).\(childKey)", into: &result)
            }
            return
        }

        diagnostics.append(.unknownKey(key))
    }

    private func validatePatch(
        _ value: JSONValue,
        at path: String,
        into changes: inout [String: JSONValue?]
    ) throws {
        if path.isEmpty {
            guard case .object(let root) = value else {
                throw GlobalSettingsStoreError.invalidSettingValue(key: "", allowed: "object")
            }
            for key in root.keys.sorted() {
                guard let child = root[key] else { continue }
                try validatePatch(child, at: key, into: &changes)
            }
            return
        }

        if path == "sharedFolders" || path.hasPrefix("sharedFolders.") {
            throw GlobalSettingsStoreError.invalidSettingValue(
                key: "sharedFolders",
                allowed: Self.sharedFoldersAllowed
            )
        }

        if let setting = setting(forKey: path) {
            if case .null = value {
                changes[path] = .some(nil)
            } else {
                if path == "runtime.userdataGiB", !limits.canFitMinimumUserdata {
                    throw GlobalSettingsStoreError.invalidSettingValue(
                        key: path,
                        allowed: "free space minus 10 GiB must be at least 8 GiB"
                    )
                }
                guard Self.isValid(value, for: setting) else {
                    throw GlobalSettingsStoreError.invalidSettingValue(
                        key: path,
                        allowed: setting.allowedValues
                    )
                }
                changes[path] = .some(value)
            }
            return
        }

        guard hasSettings(withPrefix: path + ".") else {
            throw GlobalSettingsStoreError.unknownSetting(key: path)
        }
        if case .null = value {
            for setting in settings where setting.key.hasPrefix(path + ".") {
                changes[setting.key] = .some(nil)
            }
            return
        }
        guard case .object(let object) = value else {
            throw GlobalSettingsStoreError.invalidSettingValue(
                key: path,
                allowed: "object or null"
            )
        }
        for key in object.keys.sorted() {
            guard let child = object[key] else { continue }
            try validatePatch(child, at: "\(path).\(key)", into: &changes)
        }
    }

    private func makeSnapshot() -> ConfigurationSnapshot {
        let entries = settings.map { setting in
            let defaultValue = setting.defaultValue(limits: limits)
            let storedValue = explicitValues[setting.key]
            return ConfigurationEntry(
                key: setting.key,
                value: storedValue.map { setting.effectiveValue($0, limits: limits) } ?? defaultValue,
                defaultValue: defaultValue,
                isSet: storedValue != nil,
                applies: setting.applies
            )
        }
        return ConfigurationSnapshot(entries: entries)
    }

    private var settings: [GlobalSetting] {
        Self.settings(limits: limits)
    }

    private func refreshMachineLimits() {
        guard usesCurrentLimits else { return }
        limits = .current(fileURL: fileURL)
    }

    private func setting(forKey key: String) -> GlobalSetting? {
        settings.first { $0.key == key }
    }

    private func hasSettings(withPrefix prefix: String) -> Bool {
        settings.contains { $0.key.hasPrefix(prefix) }
    }

    private func encodedSettings(_ values: [String: JSONValue]) throws -> Data {
        var root: [String: JSONValue] = ["schemaVersion": .integer(Int64(Self.currentSchemaVersion))]
        for key in values.keys.sorted() {
            guard let value = values[key] else { continue }
            Self.set(value, at: key.split(separator: ".").map(String.init), in: &root)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(root))
    }

    private static func set(
        _ value: JSONValue,
        at components: [String],
        in object: inout [String: JSONValue]
    ) {
        guard let first = components.first else { return }
        if components.count == 1 {
            object[first] = value
            return
        }
        var nested: [String: JSONValue]
        if case .object(let current)? = object[first] {
            nested = current
        } else {
            nested = [:]
        }
        set(value, at: Array(components.dropFirst()), in: &nested)
        object[first] = .object(nested)
    }

    private static func jsonObject(_ object: [String: Any]) -> [String: JSONValue]? {
        var result: [String: JSONValue] = [:]
        for (key, value) in object {
            guard let converted = jsonValue(value) else { return nil }
            result[key] = converted
        }
        return result
    }

    private static func jsonValue(_ value: Any) -> JSONValue? {
        switch value {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            } else if let integer = Int64(number.stringValue),
                Decimal(integer) == number.decimalValue
            {
                return .integer(integer)
            } else {
                return .number(number.decimalValue)
            }
        case let string as String:
            return .string(string)
        case let array as [Any]:
            let converted = array.compactMap(jsonValue)
            guard converted.count == array.count else { return nil }
            return .array(converted)
        case let object as [String: Any]:
            guard let converted = jsonObject(object) else { return nil }
            return .object(converted)
        default:
            return nil
        }
    }

    private static func isValidSharedFolderRoots(_ value: JSONValue) -> Bool {
        guard case .array(let roots) = value, roots.count <= 32 else { return false }
        var identifiers: Set<UUID> = []
        return roots.allSatisfy { root in
            guard case .object(let fields) = root,
                case .string(let id)? = fields["id"],
                let identifier = UUID(uuidString: id),
                identifiers.insert(identifier).inserted,
                case .string(let bookmark)? = fields["bookmark"],
                !bookmark.isEmpty,
                Data(base64Encoded: bookmark) != nil,
                case .string(let access)? = fields["access"],
                access == "readOnly" || access == "readWrite"
            else {
                return false
            }
            return fields.keys.allSatisfy { ["id", "bookmark", "access"].contains($0) }
        }
    }

    private func preserveMigrationBackup(for schemaVersion: Int) throws {
        let backupURL = migrationBackupURL(for: schemaVersion)
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let backupAttributes = try? FileManager.default.attributesOfItem(atPath: backupURL.path)
            let modifiedAt = backupAttributes?[.modificationDate] as? Date
            if let modifiedAt, Date().timeIntervalSince(modifiedAt) <= Self.migrationBackupRetention {
                return
            }
            do {
                try FileManager.default.removeItem(at: backupURL)
            } catch {
                throw Self.storageError(error)
            }
        }
        do {
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600, .modificationDate: Date()],
                ofItemAtPath: backupURL.path
            )
        } catch {
            throw Self.storageError(error)
        }
    }

    private func removeExpiredMigrationBackups(now: Date = Date()) {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + ".v"
        guard
            let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }
        for child in children where child.lastPathComponent.hasPrefix(prefix) && child.pathExtension == "json" {
            guard let values = try? child.resourceValues(forKeys: [.contentModificationDateKey]),
                let modifiedAt = values.contentModificationDate,
                now.timeIntervalSince(modifiedAt) > Self.migrationBackupRetention
            else {
                continue
            }
            try? FileManager.default.removeItem(at: child)
        }
    }

    private func migrationBackupURL(for schemaVersion: Int) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(fileURL.deletingPathExtension().lastPathComponent).v\(schemaVersion).json"
        )
    }

    private func corruptionArchiveURL(now: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let base = "\(fileURL.deletingPathExtension().lastPathComponent).corrupt-\(formatter.string(from: now))"
        var candidate = fileURL.deletingLastPathComponent().appendingPathComponent(base)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = fileURL.deletingLastPathComponent().appendingPathComponent("\(base)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw storageError(error)
        }

        let temporaryURL = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw posixStorageError()
        }
        var shouldRemoveTemporaryFile = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                _ = temporaryURL.path.withCString(Darwin.unlink)
            }
        }

        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let result = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        bytes.count - written
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw posixStorageError()
                    }
                    guard result > 0 else {
                        throw POSIXError(.EIO)
                    }
                    written += result
                }
            }
            guard Darwin.fcntl(descriptor, F_BARRIERFSYNC) == 0 else {
                throw posixStorageError()
            }

            let renameResult = temporaryURL.path.withCString { source in
                destination.path.withCString { target in
                    Darwin.rename(source, target)
                }
            }
            guard renameResult == 0 else {
                throw posixStorageError()
            }
            shouldRemoveTemporaryFile = false
        } catch {
            throw storageError(error)
        }
    }

    private static func posixStorageError() -> GlobalSettingsStoreError {
        let error = POSIXError(.init(rawValue: errno) ?? .EIO) as NSError
        return .storage(domain: error.domain, code: error.code)
    }

    private static func storageError(_ error: any Error) -> GlobalSettingsStoreError {
        if let error = error as? GlobalSettingsStoreError {
            return error
        }
        let error = error as NSError
        return .storage(domain: error.domain, code: error.code)
    }

    private static func settings(limits: GlobalSettingsStoreLimits) -> [GlobalSetting] {
        var result: [GlobalSetting] = [
            .enumeration(
                "runtime.startPolicy", default: "onDemand", values: ["onDemand", "atLogin"], applies: .storedOnly),
            .integer("runtime.idleSuspendMinutes", default: 10, minimum: 0, maximum: 1440, applies: .storedOnly),
            .integer("runtime.idleStopMinutes", default: 60, minimum: 0, maximum: 1440, applies: .storedOnly),
            .boolean("runtime.autoRestart", default: true, applies: .storedOnly),
            .integer(
                "runtime.cpuCount", default: min(4, limits.cpuCount), minimum: 2, maximum: limits.cpuCount,
                applies: .runtimeRestart),
            .integer(
                "runtime.memoryGiB", default: min(4, limits.memoryGiB), minimum: 3, maximum: limits.memoryGiB,
                applies: .runtimeRestart),
            .integer(
                "runtime.userdataGiB", default: min(32, limits.userdataGiB), minimum: 8, maximum: limits.userdataGiB,
                applies: .provisioning),
            .integer("runtime.bootTimeoutSeconds", default: 180, minimum: 120, maximum: 1800, applies: .nextBoot),
            .integer("runtime.firstBootTimeoutSeconds", default: 900, minimum: 600, maximum: 3600, applies: .nextBoot),
            .integer("display.maxSessions", default: 8, minimum: 1, maximum: 15, applies: .live),
            .boolean("graphics.safeMode", default: false, applies: .storedOnly),
            .boolean("audio.output", default: true, applies: .storedOnly),
            .boolean("developer.enabled", default: false, applies: .storedOnly),
            .boolean("maintenance.checkAutomatically", default: true, applies: .storedOnly),
            .enumeration("maintenance.channel", default: "stable", values: ["stable", "beta"], applies: .storedOnly),
            .boolean("maintenance.installAPKRunAutomatically", default: false, applies: .storedOnly),
            .boolean("maintenance.downloadImagesAutomatically", default: true, applies: .storedOnly),
            .enumeration(
                "maintenance.installImages", default: "automatic", values: ["automatic", "ask"], applies: .storedOnly),
            .boolean("maintenance.notifyImageInstalled", default: false, applies: .storedOnly),
            .integer(
                "updates.checkIntervalHours",
                default: 6,
                minimum: 1,
                maximum: 168,
                allowedValues: [1, 3, 6, 12, 24, 72, 168],
                applies: .storedOnly
            ),
            .boolean("updates.downloadOnExpensiveNetwork", default: false, applies: .storedOnly),
            .boolean("updates.startRuntimeToInstall", default: false, applies: .storedOnly),
            .boolean("updates.notifyInstalled", default: false, applies: .storedOnly),
            .boolean("integrations.enabled.clipboard", default: true, applies: .storedOnly),
            .boolean("integrations.enabled.notifications", default: true, applies: .storedOnly),
            .boolean("integrations.enabled.links", default: true, applies: .storedOnly),
            .boolean("integrations.enabled.files", default: true, applies: .storedOnly),
            .boolean("integrations.enabled.sharedFolders", default: true, applies: .storedOnly),
            .boolean("integrations.enabled.microphone", default: true, applies: .storedOnly),
            .boolean("integrations.defaults.clipboard", default: true, applies: .storedOnly),
            .boolean("integrations.defaults.notifications", default: true, applies: .storedOnly),
            .boolean("integrations.defaults.files", default: true, applies: .storedOnly),
            .enumeration(
                "integrations.defaults.links", default: "ask", values: ["ask", "mac", "android"], applies: .storedOnly),
            .enumeration(
                "integrations.defaults.sharedFolders", default: "off", values: ["off", "readOnly", "readWrite"],
                applies: .storedOnly),
            .boolean("integrations.defaults.microphone", default: false, applies: .storedOnly),
            .array("sharedFolders.roots", default: [], applies: .storedOnly),
            .boolean("system.syncLocale", default: true, applies: .storedOnly),
            .boolean("system.syncTimeZone", default: true, applies: .storedOnly),
            .boolean("system.syncClockFormat", default: true, applies: .storedOnly),
            .enumeration(
                "wrappers.defaultLocation",
                default: "userApplications",
                values: ["userApplications", "allUsersApplications", "ask"],
                applies: .storedOnly
            ),
        ]

        if limits.isDebugBuild {
            result += [
                .integer(
                    "graphics.limits.totalResourceMemoryMiB", default: 2048, minimum: 1, maximum: Int.max,
                    applies: .storedOnly),
                .integer(
                    "graphics.limits.maxResourceMiB", default: 256, minimum: 1, maximum: Int.max,
                    applies: .storedOnly),
                .integer(
                    "graphics.limits.maxDimension", default: 8192, minimum: 1, maximum: 16_384, applies: .storedOnly
                ),
                .integer(
                    "graphics.limits.maxContexts", default: 256, minimum: 1, maximum: Int.max, applies: .storedOnly),
                .integer(
                    "graphics.limits.maxResources", default: 65_536, minimum: 1, maximum: Int.max,
                    applies: .storedOnly),
                .integer(
                    "graphics.limits.maxBackingEntries", default: 16_384, minimum: 1, maximum: Int.max,
                    applies: .storedOnly),
                .integer(
                    "graphics.limits.maxSubmit3DMiB", default: 4, minimum: 1, maximum: Int.max, applies: .storedOnly
                ),
            ]
        }
        return result.sorted { $0.key < $1.key }
    }

    private static func isValid(_ value: JSONValue, for setting: GlobalSetting) -> Bool {
        switch (setting.kind, value) {
        case (.boolean, .bool):
            return true
        case (.integer(let minimum, let maximum, let allowedValues), .integer(let integer)):
            guard let value = Int(exactly: integer) else { return false }
            guard value >= minimum && value <= maximum else { return false }
            return allowedValues?.contains(value) ?? true
        case (.enumeration(let choices), .string(let string)):
            return choices.contains(string)
        case (.array, .array):
            return true
        default:
            return false
        }
    }

    private static func isValidStored(_ value: JSONValue, for setting: GlobalSetting) -> Bool {
        switch setting.key {
        case "runtime.cpuCount":
            guard case .integer(let integer) = value, let integer = Int(exactly: integer) else {
                return false
            }
            return (2...8).contains(integer)
        case "runtime.memoryGiB":
            guard case .integer(let integer) = value, let integer = Int(exactly: integer) else {
                return false
            }
            return integer >= 3
        case "runtime.userdataGiB":
            guard case .integer(let integer) = value, let integer = Int(exactly: integer) else {
                return false
            }
            return (8...256).contains(integer)
        default:
            return isValid(value, for: setting)
        }
    }
}

private struct GlobalSetting: Sendable {
    enum Kind: Sendable {
        case boolean
        case integer(minimum: Int, maximum: Int, allowedValues: [Int]?)
        case enumeration([String])
        case array
    }

    let key: String
    let kind: Kind
    let defaultJSONValue: JSONValue
    let applies: SettingApplies

    static func boolean(
        _ key: String,
        default value: Bool,
        applies: SettingApplies
    ) -> Self {
        Self(key: key, kind: .boolean, defaultJSONValue: .bool(value), applies: applies)
    }

    static func integer(
        _ key: String,
        default value: Int,
        minimum: Int,
        maximum: Int,
        allowedValues: [Int]? = nil,
        applies: SettingApplies
    ) -> Self {
        Self(
            key: key,
            kind: .integer(minimum: minimum, maximum: maximum, allowedValues: allowedValues),
            defaultJSONValue: .integer(Int64(value)),
            applies: applies
        )
    }

    static func enumeration(
        _ key: String,
        default value: String,
        values: [String],
        applies: SettingApplies
    ) -> Self {
        Self(key: key, kind: .enumeration(values), defaultJSONValue: .string(value), applies: applies)
    }

    static func array(
        _ key: String,
        default values: [JSONValue],
        applies: SettingApplies
    ) -> Self {
        Self(key: key, kind: .array, defaultJSONValue: .array(values), applies: applies)
    }

    func defaultValue(limits: GlobalSettingsStoreLimits) -> JSONValue {
        if key == "runtime.userdataGiB", !limits.canFitMinimumUserdata {
            return .null
        }
        return switch key {
        case "runtime.cpuCount":
            .integer(Int64(min(4, limits.cpuCount)))
        case "runtime.memoryGiB":
            .integer(Int64(min(4, limits.memoryGiB)))
        case "runtime.userdataGiB":
            .integer(Int64(min(32, limits.userdataGiB)))
        default:
            defaultJSONValue
        }
    }

    func effectiveValue(_ value: JSONValue, limits: GlobalSettingsStoreLimits) -> JSONValue {
        if key == "runtime.userdataGiB", !limits.canFitMinimumUserdata {
            return .null
        }
        guard case .integer(let integer) = value,
            let value = Int(exactly: integer)
        else {
            return value
        }
        return switch key {
        case "runtime.cpuCount":
            .integer(Int64(min(value, limits.cpuCount)))
        case "runtime.memoryGiB":
            .integer(Int64(min(value, limits.memoryGiB)))
        case "runtime.userdataGiB":
            .integer(Int64(min(value, limits.userdataGiB)))
        default:
            .integer(integer)
        }
    }

    var allowedValues: String {
        return switch kind {
        case .boolean:
            "true, false"
        case .integer(let minimum, let maximum, let allowedValues):
            if let allowedValues {
                allowedValues.map(String.init).joined(separator: ", ")
            } else if maximum == Int.max {
                "≥ \(minimum)"
            } else {
                "\(minimum)…\(maximum)"
            }
        case .enumeration(let values):
            values.joined(separator: ", ")
        case .array:
            "array"
        }
    }
}
