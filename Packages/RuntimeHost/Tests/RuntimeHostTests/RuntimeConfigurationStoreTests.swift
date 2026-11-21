import DiagnosticsCore
import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

@Test func runtimeHostConfigurationAPIReadsAndUpdatesLocaleTimeSettings() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": directory.path]
    )
    let host = RuntimeHost(
        paths: paths,
        environment: [:],
        legacySettingsSuiteName: "apkrun-tests-\(UUID().uuidString)"
    )
    try await host.start { .now }
    let before = try await host.configuration()
    #expect(
        before.entries.map(\.key) == [
            LocaleTimeConfigurationValues.syncLocaleKey,
            LocaleTimeConfigurationValues.syncTimeZoneKey,
            LocaleTimeConfigurationValues.syncClockFormatKey,
        ])
    #expect(before.entries.allSatisfy { $0.value == .bool(true) && !$0.isSet })
    #expect(!FileManager.default.fileExists(atPath: paths.settingsFile.path))

    let patch = ConfigurationPatch(
        patch: .object([
            "system": .object([
                "syncLocale": .bool(false),
                "syncTimeZone": .bool(false),
            ])
        ])
    )
    let after = try await host.updateConfiguration(patch)
    #expect(after.entries.first(where: { $0.key == "system.syncLocale" })?.value == .bool(false))
    #expect(after.entries.first(where: { $0.key == "system.syncTimeZone" })?.isSet == true)
    #expect(FileManager.default.fileExists(atPath: paths.settingsFile.path))
    await host.shutdown()
}

@Test func runtimeHostRejectsUnknownConfigurationWithoutPartialUpdate() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": directory.path]
    )
    let host = RuntimeHost(
        paths: paths,
        environment: [:],
        legacySettingsSuiteName: "apkrun-tests-\(UUID().uuidString)"
    )
    try await host.start { .now }
    let patch = ConfigurationPatch(
        patch: .object([
            "system": .object([
                "syncLocale": .bool(false),
                "futureKey": .bool(true),
            ])
        ])
    )

    await #expect(throws: RuntimeConfigurationStoreError.unknownSetting("system.futureKey")) {
        try await host.updateConfiguration(patch)
    }
    let after = try await host.configuration()
    #expect(after.entries.allSatisfy { $0.value == .bool(true) && !$0.isSet })
    #expect(!FileManager.default.fileExists(atPath: paths.settingsFile.path))
    await host.shutdown()
}

@Test func runtimeHostRefusesConfigurationChangesWithoutTheInstanceLock() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": directory.path]
    )
    let suiteName = "apkrun-tests-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    let key = LocaleTimeConfigurationValues.syncLocaleKey
    let previousValue = preferences.object(forKey: key)
    preferences.set(false, forKey: key)
    defer {
        if let previousValue {
            preferences.set(previousValue, forKey: key)
        } else {
            preferences.removeObject(forKey: key)
        }
    }
    let competingLock = try InstanceLock.acquire(paths: paths, owner: .apkrunDev)
    defer { competingLock.close() }
    let host = RuntimeHost(
        paths: paths,
        environment: [:],
        legacySettingsSuiteName: suiteName
    )

    try await host.start { .now }
    await #expect(throws: RuntimeHostError.runtimeFailure(.instanceLocked(owner: .unknown))) {
        try await host.updateConfiguration(
            ConfigurationPatch(
                patch: .object(["system": .object(["syncLocale": .bool(false)])])
            )
        )
    }

    #expect(preferences.object(forKey: key) as? Bool == false)
    #expect(!FileManager.default.fileExists(atPath: paths.settingsFile.path))
    await host.shutdown()
}

@Test func newerSettingsSchemaDegradesStartupAndRemainsUntouched() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": directory.path]
    )
    try FileManager.default.createDirectory(at: paths.dataRoot, withIntermediateDirectories: true)
    let original = Data(#"{"schemaVersion":3,"system":{"syncLocale":false}}"#.utf8)
    try original.write(to: paths.settingsFile)
    let host = RuntimeHost(
        paths: paths,
        environment: [:],
        legacySettingsSuiteName: "apkrun-tests-\(UUID().uuidString)"
    )

    try await host.start { .now }

    let status = await host.status()
    #expect(status.hostState == "degraded")
    #expect(status.startupFailureStep == 4)
    #expect(status.startupFailureCode == RuntimeHost.newerSettingsSchemaFailureCode)
    #expect(!status.crashLoopActive)
    await #expect(
        throws: RuntimeHostError.startupFailed(
            step: 4,
            code: RuntimeHost.newerSettingsSchemaFailureCode
        )
    ) {
        try await host.configuration()
    }
    await #expect(
        throws: RuntimeHostError.startupFailed(
            step: 4,
            code: RuntimeHost.newerSettingsSchemaFailureCode
        )
    ) {
        try await host.updateConfiguration(
            ConfigurationPatch(patch: .object(["system": .object(["syncLocale": .bool(true)])]))
        )
    }

    #expect(try Data(contentsOf: paths.settingsFile) == original)
    await host.shutdown()
}

@Test func localeTimeConfigurationDefaultsWithoutCreatingSettingsFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let values = try RuntimeConfigurationStore(fileURL: fileURL).localeTimeSettings()

    #expect(values.syncLocale)
    #expect(values.syncTimeZone)
    #expect(values.syncClockFormat)
    #expect(values.explicitlySetKeys.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
}

@Test func localeTimeConfigurationPatchPreservesOtherSettingsAndSkipsNoOps() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let original: [String: Any] = [
        "schemaVersion": RuntimeConfigurationStore.currentSchemaVersion,
        "runtime": ["memoryGiB": 6],
        "futureRoot": ["unexpected": true],
        "system": ["syncLocale": true, "syncTimeZone": true, "customOption": "drop"],
    ]
    try JSONSerialization.data(withJSONObject: original).write(to: fileURL)
    let store = RuntimeConfigurationStore(fileURL: fileURL)

    let first = try store.updateLocaleTimeSettings([
        LocaleTimeConfigurationValues.syncLocaleKey: .set(false),
        LocaleTimeConfigurationValues.syncClockFormatKey: .set(false),
    ])
    #expect(
        first.changedKeys == [
            LocaleTimeConfigurationValues.syncClockFormatKey,
            LocaleTimeConfigurationValues.syncLocaleKey,
        ])
    #expect(!first.values.syncLocale)
    #expect(!first.values.syncClockFormat)
    #expect(first.values.syncTimeZone)

    let saved = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    #expect(saved["runtime"] as? [String: Int] == ["memoryGiB": 6])
    #expect(saved["futureRoot"] == nil)
    let savedSystem = try #require(saved["system"] as? [String: Any])
    #expect(savedSystem["customOption"] == nil)
    #expect(savedSystem["syncLocale"] as? Bool == false)

    let beforeNoOp = try Data(contentsOf: fileURL)
    let noOp = try store.updateLocaleTimeSettings([
        LocaleTimeConfigurationValues.syncLocaleKey: .set(false)
    ])
    #expect(noOp.changedKeys.isEmpty)
    #expect(try Data(contentsOf: fileURL) == beforeNoOp)
}

@Test func settingsDirectoryAtFilePathIsNotQuarantined() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let settingsDirectory = directory.appendingPathComponent("settings.json", isDirectory: true)
    try FileManager.default.createDirectory(
        at: settingsDirectory,
        withIntermediateDirectories: true
    )
    let store = RuntimeConfigurationStore(fileURL: settingsDirectory)

    #expect(throws: RuntimeConfigurationStoreError.unreadable) {
        try store.localeTimeSettings()
    }
    #expect(FileManager.default.fileExists(atPath: settingsDirectory.path))
}

@Test func invalidStoredSettingUsesItsDefaultAndIsDroppedOnTheNextWrite() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let original = Data(
        #"{"schemaVersion":2,"runtime":{"memoryGiB":6},"system":{"syncLocale":"false","syncTimeZone":false,"syncClockFormat":true,"futureKey":1}}"#
            .utf8
    )
    try original.write(to: fileURL)
    let store = RuntimeConfigurationStore(fileURL: fileURL)

    let read = try store.readLocaleTimeSettings()
    #expect(read.values.syncLocale)
    #expect(!read.values.explicitlySetKeys.contains(LocaleTimeConfigurationValues.syncLocaleKey))
    #expect(!read.values.syncTimeZone)
    #expect(read.values.syncClockFormat)
    #expect(read.issues.contains(.invalidSettingValue(LocaleTimeConfigurationValues.syncLocaleKey)))
    #expect(read.issues.contains(.unknownSetting("system.futureKey")))

    let update = try store.updateLocaleTimeSettings([
        LocaleTimeConfigurationValues.syncTimeZoneKey: .set(true)
    ])
    #expect(update.changedKeys == [LocaleTimeConfigurationValues.syncTimeZoneKey])
    let saved = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    #expect(saved["runtime"] as? [String: Int] == ["memoryGiB": 6])
    let system = try #require(saved["system"] as? [String: Any])
    #expect(system["syncLocale"] == nil)
    #expect(system["futureKey"] == nil)
    #expect(system["syncTimeZone"] as? Bool == true)
    #expect(system["syncClockFormat"] as? Bool == true)
}

@Test func settingAnInvalidStoredValueToItsDefaultMakesItExplicit() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    try Data(#"{"schemaVersion":2,"system":{"syncLocale":"invalid"}}"#.utf8).write(to: fileURL)
    let store = RuntimeConfigurationStore(fileURL: fileURL)

    let result = try store.updateLocaleTimeSettings([
        LocaleTimeConfigurationValues.syncLocaleKey: .set(true)
    ])

    #expect(result.changedKeys == [LocaleTimeConfigurationValues.syncLocaleKey])
    #expect(result.values.syncLocale)
    #expect(result.values.explicitlySetKeys.contains(LocaleTimeConfigurationValues.syncLocaleKey))
}

@Test func schemaBackupRetentionExpiresAtNinetyDays() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    try Data(#"{"schemaVersion":2}"#.utf8).write(to: fileURL)
    let expiredBackup = directory.appendingPathComponent("settings.json.v1.json")
    let retainedBackup = directory.appendingPathComponent("settings.json.v2.json")
    let unrelatedFile = directory.appendingPathComponent("settings.json.vfuture.json")
    try Data("expired".utf8).write(to: expiredBackup)
    try Data("retained".utf8).write(to: retainedBackup)
    try Data("unrelated".utf8).write(to: unrelatedFile)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-90 * 24 * 60 * 60)],
        ofItemAtPath: expiredBackup.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: now.addingTimeInterval(-90 * 24 * 60 * 60 + 1)],
        ofItemAtPath: retainedBackup.path
    )
    RuntimeConfigurationStore(fileURL: fileURL).pruneExpiredSchemaBackups(now: now)

    #expect(!FileManager.default.fileExists(atPath: expiredBackup.path))
    #expect(FileManager.default.fileExists(atPath: retainedBackup.path))
    #expect(FileManager.default.fileExists(atPath: unrelatedFile.path))
}

@Test func corruptAndMissingSchemaSettingsFilesAreQuarantined() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let corruptInputs = [
        Data("{invalid json".utf8),
        Data(#"{"system":{"syncLocale":false}}"#.utf8),
    ]
    for (index, original) in corruptInputs.enumerated() {
        let caseDirectory = directory.appendingPathComponent("case-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        let fileURL = caseDirectory.appendingPathComponent("settings.json")
        try original.write(to: fileURL)
        let store = RuntimeConfigurationStore(fileURL: fileURL)

        let read = try store.readLocaleTimeSettings()
        #expect(read.values.syncLocale)
        #expect(read.values.syncTimeZone)
        #expect(read.values.syncClockFormat)
        #expect(read.issues.contains(.corruptFileQuarantined))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        let quarantinedFiles = try FileManager.default.contentsOfDirectory(
            atPath: caseDirectory.path
        )
        #expect(quarantinedFiles.contains { $0.hasPrefix("settings.json.corrupt-") })

        _ = try store.updateLocaleTimeSettings([
            LocaleTimeConfigurationValues.syncLocaleKey: .set(false)
        ])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try store.localeTimeSettings().syncLocale == false)
    }
}

@Test func resettingLocaleTimeSettingRestoresDefaultAndRemovesStoredKey() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("settings.json")
    let store = RuntimeConfigurationStore(fileURL: fileURL)
    _ = try store.updateLocaleTimeSettings([
        LocaleTimeConfigurationValues.syncTimeZoneKey: .set(false)
    ])

    let result = try store.updateLocaleTimeSettings([
        LocaleTimeConfigurationValues.syncTimeZoneKey: .reset
    ])

    #expect(result.changedKeys == [LocaleTimeConfigurationValues.syncTimeZoneKey])
    #expect(result.values.syncTimeZone)
    #expect(!result.values.explicitlySetKeys.contains(LocaleTimeConfigurationValues.syncTimeZoneKey))
    let saved = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    #expect(saved["system"] == nil)
}

@Test func unknownConfigurationKeyDoesNotPartiallyApplyPatch() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let original = Data(
        #"{"schemaVersion":2,"system":{"syncLocale":true}}"#.utf8
    )
    try original.write(to: fileURL)
    let store = RuntimeConfigurationStore(fileURL: fileURL)

    #expect(throws: RuntimeConfigurationStoreError.unknownSetting("system.futureKey")) {
        try store.updateLocaleTimeSettings([
            LocaleTimeConfigurationValues.syncLocaleKey: .set(false),
            "system.futureKey": .set(true),
        ])
    }
    #expect(try Data(contentsOf: fileURL) == original)
}

@Test func legacyLocaleTimePreferencesImportOnlyUnstoredValues() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("settings.json")
    let store = RuntimeConfigurationStore(fileURL: fileURL)
    _ = try store.updateLocaleTimeSettings([
        LocaleTimeConfigurationValues.syncLocaleKey: .set(true)
    ])
    let imported = try store.importLegacyPreferences([
        LocaleTimeConfigurationValues.syncLocaleKey: false,
        LocaleTimeConfigurationValues.syncTimeZoneKey: false,
        LocaleTimeConfigurationValues.syncClockFormatKey: true,
    ])

    #expect(
        imported == [
            LocaleTimeConfigurationValues.syncClockFormatKey,
            LocaleTimeConfigurationValues.syncTimeZoneKey,
        ])
    let values = try store.localeTimeSettings()
    #expect(values.syncLocale)
    #expect(!values.syncTimeZone)
    #expect(values.syncClockFormat)
}

@Test func olderSettingsSchemaIsBackedUpBeforeMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let original = Data(#"{"schemaVersion":1,"runtime":{"memoryGiB":6}}"#.utf8)
    try original.write(to: fileURL)
    let store = RuntimeConfigurationStore(fileURL: fileURL)

    _ = try store.localeTimeSettings()

    let migrated = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
    )
    let backupURL = directory.appendingPathComponent("settings.json.v1.json")
    #expect(migrated["schemaVersion"] as? Int == RuntimeConfigurationStore.currentSchemaVersion)
    #expect(try Data(contentsOf: backupURL) == original)
    #expect(migrated["runtime"] as? [String: Int] == ["memoryGiB": 6])
}
