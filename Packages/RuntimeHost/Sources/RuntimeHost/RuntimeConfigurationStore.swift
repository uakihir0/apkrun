import CoreFoundation
import Darwin
import Foundation

struct LocaleTimeConfigurationValues: Equatable, Sendable {
    var syncLocale = true
    var syncTimeZone = true
    var syncClockFormat = true
    var explicitlySetKeys = Set<String>()

    static let syncLocaleKey = "system.syncLocale"
    static let syncTimeZoneKey = "system.syncTimeZone"
    static let syncClockFormatKey = "system.syncClockFormat"

    subscript(key: String) -> Bool {
        get {
            switch key {
            case Self.syncLocaleKey: syncLocale
            case Self.syncTimeZoneKey: syncTimeZone
            case Self.syncClockFormatKey: syncClockFormat
            default: true
            }
        }
        set {
            switch key {
            case Self.syncLocaleKey: syncLocale = newValue
            case Self.syncTimeZoneKey: syncTimeZone = newValue
            case Self.syncClockFormatKey: syncClockFormat = newValue
            default: break
            }
        }
    }
}

enum LocaleTimeSettingMutation: Equatable, Sendable {
    case set(Bool)
    case reset
}

enum RuntimeConfigurationStoreError: Error, Equatable, Sendable {
    case unreadable
    case unsupportedSchema(Int)
    case unknownSetting(String)
    case invalidSettingValue(String)
    case writeFailed
}

enum RuntimeConfigurationStoreIssue: Equatable, Sendable {
    case corruptFileQuarantined
    case unknownSetting(String)
    case invalidSettingValue(String)
}

struct RuntimeConfigurationStore: Sendable {
    static let currentSchemaVersion = 2
    static let maximumFileSize = 1024 * 1024

    let fileURL: URL

    func localeTimeSettings() throws -> LocaleTimeConfigurationValues {
        try readLocaleTimeSettings().values
    }

    func readLocaleTimeSettings() throws -> (
        values: LocaleTimeConfigurationValues,
        issues: [RuntimeConfigurationStoreIssue]
    ) {
        var document = try loadDocument()
        if let oldSchema = document.schemaVersion, oldSchema < Self.currentSchemaVersion {
            try migrate(&document, from: oldSchema)
        }
        return (Self.localeTimeValues(in: document.object), document.issues)
    }

    func updateLocaleTimeSettings(
        _ patch: [String: LocaleTimeSettingMutation]
    ) throws -> (
        values: LocaleTimeConfigurationValues,
        changedKeys: [String],
        issues: [RuntimeConfigurationStoreIssue]
    ) {
        var document = try loadDocument()
        if let oldSchema = document.schemaVersion, oldSchema < Self.currentSchemaVersion {
            try migrate(&document, from: oldSchema)
        }

        var values = Self.localeTimeValues(in: document.object)
        var root = document.object
        var system = root["system"] as? [String: Any] ?? [:]
        var changedKeys: [String] = []
        for (key, mutation) in patch.sorted(by: { $0.key < $1.key }) {
            guard Self.localeTimeKeys.contains(key) else {
                throw RuntimeConfigurationStoreError.unknownSetting(key)
            }
            let shortKey = String(key.dropFirst("system.".count))
            switch mutation {
            case .set(let newValue):
                let storedValue = system[shortKey]
                let wasSet = Self.boolean(storedValue) != nil
                let oldValue = values[key]
                guard !wasSet || oldValue != newValue else { continue }
                system[shortKey] = newValue
                values[key] = newValue
                values.explicitlySetKeys.insert(key)
                changedKeys.append(key)
            case .reset:
                guard system.removeValue(forKey: shortKey) != nil else { continue }
                values[key] = true
                values.explicitlySetKeys.remove(key)
                changedKeys.append(key)
            }
        }

        let shouldNormalize = document.issues.contains {
            switch $0 {
            case .unknownSetting, .invalidSettingValue: true
            case .corruptFileQuarantined: false
            }
        }
        guard !changedKeys.isEmpty || shouldNormalize else {
            return (values, [], document.issues)
        }

        if system.isEmpty {
            root.removeValue(forKey: "system")
        } else {
            root["system"] = system
        }
        root = Self.cleanedObjectForWrite(root)
        root["schemaVersion"] = Self.currentSchemaVersion
        try write(root)
        return (Self.localeTimeValues(in: root), changedKeys, document.issues)
    }

    func importLegacyPreferences(_ preferences: [String: Bool]) throws -> [String] {
        let values = try localeTimeSettings()
        var patch: [String: LocaleTimeSettingMutation] = [:]
        for (key, value) in preferences
        where Self.localeTimeKeys.contains(key) && !values.explicitlySetKeys.contains(key) {
            patch[key] = .set(value)
        }
        guard !patch.isEmpty else { return [] }
        return try updateLocaleTimeSettings(patch).changedKeys
    }

    private static let localeTimeKeys: Set<String> = [
        LocaleTimeConfigurationValues.syncLocaleKey,
        LocaleTimeConfigurationValues.syncTimeZoneKey,
        LocaleTimeConfigurationValues.syncClockFormatKey,
    ]

    private static let localeTimeShortKeys: Set<String> = [
        "syncLocale",
        "syncTimeZone",
        "syncClockFormat",
    ]

    private static let knownRootKeys: Set<String> = [
        "audio",
        "developer",
        "display",
        "graphics",
        "integrations",
        "maintenance",
        "runtime",
        "sharedFolders",
        "system",
        "updates",
        "wrappers",
    ]

    private struct LoadedDocument {
        var object: [String: Any]
        var schemaVersion: Int?
        var wasPresent: Bool
        var issues: [RuntimeConfigurationStoreIssue]
    }

    func pruneExpiredSchemaBackups(now: Date = Date()) {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = "\(fileURL.lastPathComponent).v"
        let suffix = ".json"
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        for name in names {
            guard name.hasPrefix(prefix),
                name.hasSuffix(suffix),
                let version = Int(name.dropFirst(prefix.count).dropLast(suffix.count)),
                version > 0
            else {
                continue
            }
            let backupURL = directory.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: backupURL.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                let modificationDate = attributes[.modificationDate] as? Date,
                modificationDate <= cutoff
            else {
                continue
            }
            try? FileManager.default.removeItem(at: backupURL)
        }
    }

    private func loadDocument() throws -> LoadedDocument {
        pruneExpiredSchemaBackups()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return LoadedDocument(
                object: ["schemaVersion": Self.currentSchemaVersion],
                schemaVersion: nil,
                wasPresent: false,
                issues: []
            )
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw RuntimeConfigurationStoreError.unreadable
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber
        else {
            throw RuntimeConfigurationStoreError.unreadable
        }
        guard size.intValue <= Self.maximumFileSize else {
            return try quarantineCorruptFile()
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw RuntimeConfigurationStoreError.unreadable
        }
        let object: [String: Any]
        do {
            guard let parsedObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return try quarantineCorruptFile()
            }
            object = parsedObject
        } catch {
            return try quarantineCorruptFile()
        }
        guard let rawSchemaVersion = object["schemaVersion"] as? NSNumber,
            CFGetTypeID(rawSchemaVersion) != CFBooleanGetTypeID(),
            rawSchemaVersion.doubleValue.rounded() == rawSchemaVersion.doubleValue
        else {
            return try quarantineCorruptFile()
        }
        let schemaVersion = rawSchemaVersion.intValue
        guard schemaVersion > 0 else {
            return try quarantineCorruptFile()
        }
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw RuntimeConfigurationStoreError.unsupportedSchema(schemaVersion)
        }
        var normalizedObject = object
        var issues: [RuntimeConfigurationStoreIssue] = []
        for key in object.keys where key != "schemaVersion" && !Self.knownRootKeys.contains(key) {
            issues.append(.unknownSetting(key))
        }
        if let rawSystem = object["system"] {
            guard let system = rawSystem as? [String: Any] else {
                normalizedObject.removeValue(forKey: "system")
                issues.append(.invalidSettingValue("system"))
                return LoadedDocument(
                    object: normalizedObject,
                    schemaVersion: schemaVersion,
                    wasPresent: true,
                    issues: issues
                )
            }
            for key in system.keys where !Self.localeTimeShortKeys.contains(key) {
                issues.append(.unknownSetting("system.\(key)"))
            }
            for key in Self.localeTimeKeys {
                let shortKey = String(key.dropFirst("system.".count))
                if let value = system[shortKey], Self.boolean(value) == nil {
                    issues.append(.invalidSettingValue(key))
                }
            }
        }
        return LoadedDocument(
            object: normalizedObject,
            schemaVersion: schemaVersion,
            wasPresent: true,
            issues: issues
        )
    }

    private func quarantineCorruptFile() throws -> LoadedDocument {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let quarantineDirectory = fileURL.deletingLastPathComponent()
        var quarantineName = "\(fileURL.lastPathComponent).corrupt-\(timestamp)"
        var quarantineURL =
            quarantineDirectory
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(timestamp)")
        if FileManager.default.fileExists(atPath: quarantineURL.path) {
            quarantineName += "-\(UUID().uuidString)"
            quarantineURL = quarantineDirectory.appendingPathComponent(quarantineName)
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
        } catch {
            throw RuntimeConfigurationStoreError.writeFailed
        }
        return LoadedDocument(
            object: ["schemaVersion": Self.currentSchemaVersion],
            schemaVersion: nil,
            wasPresent: false,
            issues: [.corruptFileQuarantined]
        )
    }

    private func migrate(_ document: inout LoadedDocument, from oldSchema: Int) throws {
        guard document.wasPresent else { return }
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).v\(oldSchema).json")
        if !FileManager.default.fileExists(atPath: backupURL.path) {
            do {
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
                try FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: backupURL.path
                )
            } catch {
                throw RuntimeConfigurationStoreError.writeFailed
            }
        }
        document.object["schemaVersion"] = Self.currentSchemaVersion
        document.object = Self.cleanedObjectForWrite(document.object)
        try write(document.object)
        document.schemaVersion = Self.currentSchemaVersion
    }

    private static func localeTimeValues(in object: [String: Any]) -> LocaleTimeConfigurationValues {
        var values = LocaleTimeConfigurationValues()
        guard let system = object["system"] as? [String: Any] else {
            return values
        }
        for key in localeTimeKeys {
            let shortKey = String(key.dropFirst("system.".count))
            guard let storedValue = system[shortKey] else { continue }
            guard let boolValue = boolean(storedValue) else {
                continue
            }
            values[key] = boolValue
            values.explicitlySetKeys.insert(key)
        }
        return values
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func cleanedObjectForWrite(_ object: [String: Any]) -> [String: Any] {
        var result = object
        for key in Array(result.keys)
        where key != "schemaVersion" && !knownRootKeys.contains(key) {
            result.removeValue(forKey: key)
        }
        guard var system = result["system"] as? [String: Any] else {
            result.removeValue(forKey: "system")
            return result
        }
        for key in Array(system.keys) where !localeTimeShortKeys.contains(key) {
            system.removeValue(forKey: key)
        }
        for key in localeTimeShortKeys {
            if let value = system[key], boolean(value) == nil {
                system.removeValue(forKey: key)
            }
        }
        if system.isEmpty {
            result.removeValue(forKey: "system")
        } else {
            result["system"] = system
        }
        return result
    }

    private func write(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw RuntimeConfigurationStoreError.writeFailed
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw RuntimeConfigurationStoreError.writeFailed
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw RuntimeConfigurationStoreError.writeFailed
        }

        let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(S_IRUSR | S_IWUSR))
        }
        guard descriptor >= 0 else {
            throw RuntimeConfigurationStoreError.writeFailed
        }
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else {
                        throw RuntimeConfigurationStoreError.writeFailed
                    }
                    offset += written
                }
            }
            guard Darwin.fcntl(descriptor, F_BARRIERFSYNC) == 0 else {
                throw RuntimeConfigurationStoreError.writeFailed
            }
            let renameResult = temporaryURL.path.withCString { temporaryPath in
                fileURL.path.withCString { destinationPath in
                    Darwin.rename(temporaryPath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw RuntimeConfigurationStoreError.writeFailed
            }
        } catch let error as RuntimeConfigurationStoreError {
            throw error
        } catch {
            throw RuntimeConfigurationStoreError.writeFailed
        }
    }
}
