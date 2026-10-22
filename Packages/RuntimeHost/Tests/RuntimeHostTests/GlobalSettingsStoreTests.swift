import Foundation
import RuntimeAPI
import Testing

@testable import RuntimeHost

private func makeSettingsURL() -> (directory: URL, file: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-global-settings-\(UUID().uuidString)", isDirectory: true)
    return (directory, directory.appendingPathComponent("settings.json"))
}

private func setting(_ key: String, in snapshot: ConfigurationSnapshot) -> ConfigurationEntry? {
    snapshot.entries.first { $0.key == key }
}

private let testLimits = GlobalSettingsStoreLimits(
    cpuCount: 8,
    memoryGiB: 12,
    userdataGiB: 128,
    isDebugBuild: true
)

@Test func globalSettingsSnapshotIncludesEverySettingInSortedOrder() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)

    let snapshot = try await store.snapshot()
    let keys = snapshot.entries.map(\.key)
    #expect(keys == keys.sorted())
    #expect(setting("runtime.startPolicy", in: snapshot)?.value == .string("onDemand"))
    #expect(setting("runtime.memoryGiB", in: snapshot)?.defaultValue == .integer(4))
    #expect(setting("runtime.memoryGiB", in: snapshot)?.isSet == false)
    #expect(setting("sharedFolders.roots", in: snapshot)?.value == .array([]))
    #expect(setting("graphics.limits.maxDimension", in: snapshot)?.value == .integer(8192))
    #expect(setting("wrappers.defaultLocation", in: snapshot)?.applies == .live)
}

@Test func globalSettingsUpdatesValidatePersistAndPreserveExplicitDefaults() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)
    let defaultPatch = ConfigurationPatch(
        patch: .object(["runtime": .object(["startPolicy": .string("onDemand")])])
    )

    let first = try await store.update(defaultPatch)
    #expect(first.changedKeys == ["runtime.startPolicy"])
    #expect(setting("runtime.startPolicy", in: first.snapshot)?.isSet == true)
    #expect(await store.successfulWriteCount == 1)

    let repeated = try await store.update(defaultPatch)
    #expect(repeated.changedKeys.isEmpty)
    #expect(await store.successfulWriteCount == 1)

    let data = try Data(contentsOf: location.file)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(root["schemaVersion"] as? Int == 2)
    let runtime = try #require(root["runtime"] as? [String: Any])
    #expect(runtime["startPolicy"] as? String == "onDemand")

    let reset = try await store.update(
        ConfigurationPatch(patch: .object(["runtime": .object(["startPolicy": .null])]))
    )
    #expect(reset.changedKeys == ["runtime.startPolicy"])
    #expect(setting("runtime.startPolicy", in: reset.snapshot)?.isSet == false)
    #expect(await store.successfulWriteCount == 2)
}

@Test func globalSettingsRejectsWholeInvalidPatchWithoutWriting() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)
    let patch = ConfigurationPatch(
        patch: .object([
            "maintenance": .object(["channel": .string("beta")]),
            "runtime": .object(["idleStopMinutes": .integer(1441)]),
        ])
    )

    await #expect(
        throws: GlobalSettingsStoreError.invalidSettingValue(
            key: "runtime.idleStopMinutes",
            allowed: "0…1440"
        )
    ) {
        try await store.update(patch)
    }
    #expect(await store.successfulWriteCount == 0)
    #expect(!FileManager.default.fileExists(atPath: location.file.path))
    #expect(setting("maintenance.channel", in: try await store.snapshot())?.value == .string("stable"))
}

@Test func globalSettingsRejectsUnknownAndSharedFolderPatchKeys() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)

    await #expect(throws: GlobalSettingsStoreError.unknownSetting(key: "runtime.unknown")) {
        try await store.update(
            ConfigurationPatch(patch: .object(["runtime": .object(["unknown": .bool(true)])]))
        )
    }
    await #expect(
        throws: GlobalSettingsStoreError.invalidSettingValue(
            key: "sharedFolders",
            allowed: "Use apkrun shared-folders."
        )
    ) {
        try await store.update(
            ConfigurationPatch(patch: .object(["sharedFolders": .object(["roots": .array([])])]))
        )
    }
    #expect(await store.successfulWriteCount == 0)
}

@Test func globalSettingsClampsMachineDependentValuesWithoutChangingTheFile() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
        at: location.directory,
        withIntermediateDirectories: true
    )
    let original = Data(
        #"{"schemaVersion":2,"runtime":{"cpuCount":8,"memoryGiB":8,"userdataGiB":64}}"#.utf8
    )
    try original.write(to: location.file)
    let store = GlobalSettingsStore(
        fileURL: location.file,
        limits: GlobalSettingsStoreLimits(cpuCount: 4, memoryGiB: 6, userdataGiB: 32, isDebugBuild: false)
    )

    let snapshot = try await store.snapshot()
    #expect(setting("runtime.cpuCount", in: snapshot)?.value == .integer(4))
    #expect(setting("runtime.cpuCount", in: snapshot)?.isSet == true)
    #expect(setting("runtime.memoryGiB", in: snapshot)?.value == .integer(6))
    #expect(setting("runtime.userdataGiB", in: snapshot)?.value == .integer(32))
    #expect(try Data(contentsOf: location.file) == original)
    #expect(await store.successfulWriteCount == 0)
}

@Test func globalSettingsRejectsUserdataWhenTheFreeSpaceReserveLeavesNoValidSize() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = GlobalSettingsStore(
        fileURL: location.file,
        limits: GlobalSettingsStoreLimits(
            cpuCount: 8,
            memoryGiB: 12,
            userdataGiB: 7,
            isDebugBuild: false
        )
    )

    await #expect(
        throws: GlobalSettingsStoreError.invalidSettingValue(
            key: "runtime.userdataGiB",
            allowed: "free space minus 10 GiB must be at least 8 GiB"
        )
    ) {
        try await store.update(
            ConfigurationPatch(patch: .object(["runtime": .object(["userdataGiB": .integer(8)])]))
        )
    }
    #expect(await store.successfulWriteCount == 0)
    #expect(!FileManager.default.fileExists(atPath: location.file.path))
}

@Test func globalSettingsReportsUnavailableUserdataAndSupportsResetBelowTheMinimumCapacity() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
        at: location.directory,
        withIntermediateDirectories: true
    )
    try Data(#"{"schemaVersion":2,"runtime":{"userdataGiB":32}}"#.utf8).write(to: location.file)
    let store = GlobalSettingsStore(
        fileURL: location.file,
        limits: GlobalSettingsStoreLimits(
            cpuCount: 8,
            memoryGiB: 12,
            userdataGiB: 7,
            isDebugBuild: false
        )
    )

    let beforeReset = try await store.snapshot()
    #expect(setting("runtime.userdataGiB", in: beforeReset)?.value == .null)
    #expect(setting("runtime.userdataGiB", in: beforeReset)?.defaultValue == .null)
    #expect(setting("runtime.userdataGiB", in: beforeReset)?.isSet == true)

    let reset = try await store.update(
        ConfigurationPatch(patch: .object(["runtime": .object(["userdataGiB": .null])]))
    )
    #expect(reset.changedKeys == ["runtime.userdataGiB"])
    #expect(setting("runtime.userdataGiB", in: reset.snapshot)?.value == .null)
    #expect(setting("runtime.userdataGiB", in: reset.snapshot)?.isSet == false)
    #expect(await store.successfulWriteCount == 1)
}

@Test func globalSettingsIgnoresUnknownAndInvalidStoredValues() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
        at: location.directory,
        withIntermediateDirectories: true
    )
    try Data(
        #"{"schemaVersion":2,"future":{"key":1},"runtime":{"autoRestart":"yes","idleStopMinutes":20}}"#.utf8
    ).write(to: location.file)
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)

    let loaded = try await store.load()
    #expect(setting("runtime.autoRestart", in: loaded.snapshot)?.value == .bool(true))
    #expect(setting("runtime.autoRestart", in: loaded.snapshot)?.isSet == false)
    #expect(setting("runtime.idleStopMinutes", in: loaded.snapshot)?.value == .integer(20))
    #expect(loaded.diagnostics.contains(.unknownKey("future")))
    #expect(loaded.diagnostics.contains(.invalidValue("runtime.autoRestart")))
    #expect(await store.successfulWriteCount == 0)
}

@Test func globalSettingsMigratesSchemaOneAndKeepsOneBackup() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
        at: location.directory,
        withIntermediateDirectories: true
    )
    try Data(#"{"schemaVersion":1,"runtime":{"idleSuspendMinutes":15}}"#.utf8).write(to: location.file)
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)

    let loaded = try await store.load()
    #expect(loaded.diagnostics.contains(.migrated(fromSchema: 1)))
    #expect(setting("runtime.idleSuspendMinutes", in: loaded.snapshot)?.value == .integer(15))
    #expect(await store.successfulWriteCount == 1)
    #expect(
        FileManager.default.fileExists(
            atPath: location.directory.appendingPathComponent("settings.v1.json").path
        ))
    let root = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: location.file)) as? [String: Any]
    )
    #expect(root["schemaVersion"] as? Int == 2)
}

@Test func globalSettingsRefreshesAnExpiredMigrationBackupBeforePruning() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
        at: location.directory,
        withIntermediateDirectories: true
    )
    let original = Data(#"{"schemaVersion":1,"runtime":{"idleSuspendMinutes":15}}"#.utf8)
    try original.write(to: location.file)
    let backupURL = location.directory.appendingPathComponent("settings.v1.json")
    try Data(#"{"schemaVersion":1,"runtime":{"idleSuspendMinutes":2}}"#.utf8).write(to: backupURL)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSinceNow: -91 * 24 * 60 * 60)],
        ofItemAtPath: backupURL.path
    )
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)

    _ = try await store.load()

    #expect(try Data(contentsOf: backupURL) == original)
    #expect(
        try backupURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            .map { Date().timeIntervalSince($0) < 60 } == true
    )
    #expect(await store.successfulWriteCount == 1)
}

@Test func globalSettingsQuarantinesMalformedFileAndUsesDefaults() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
        at: location.directory,
        withIntermediateDirectories: true
    )
    try Data(#"{"runtime":{"autoRestart":false}}"#.utf8).write(to: location.file)
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)

    let loaded = try await store.load()
    #expect(setting("runtime.autoRestart", in: loaded.snapshot)?.value == .bool(true))
    guard case .corruptFile(let archiveName)? = loaded.diagnostics.first else {
        Issue.record("Expected malformed settings file to be quarantined.")
        return
    }
    #expect(archiveName.hasPrefix("settings.corrupt-"))
    #expect(FileManager.default.fileExists(atPath: location.directory.appendingPathComponent(archiveName).path))
    #expect(!FileManager.default.fileExists(atPath: location.file.path))
}

@Test func globalSettingsNewerSchemaIsReadOnlyForReadsAndWrites() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
        at: location.directory,
        withIntermediateDirectories: true
    )
    let original = Data(#"{"schemaVersion":3,"runtime":{"autoRestart":false}}"#.utf8)
    try original.write(to: location.file)
    let store = GlobalSettingsStore(fileURL: location.file, limits: testLimits)

    await #expect(throws: GlobalSettingsStoreError.unsupportedSchema(version: 3)) {
        try await store.snapshot()
    }
    await #expect(throws: GlobalSettingsStoreError.unsupportedSchema(version: 3)) {
        try await store.update(
            ConfigurationPatch(patch: .object(["runtime": .object(["autoRestart": .bool(true)])]))
        )
    }
    #expect(try Data(contentsOf: location.file) == original)
    #expect(await store.successfulWriteCount == 0)
}

@Test func globalSettingsGraphicsLimitsAreDebugOnly() async throws {
    let location = makeSettingsURL()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let releaseStore = GlobalSettingsStore(
        fileURL: location.file,
        limits: GlobalSettingsStoreLimits(cpuCount: 8, memoryGiB: 12, userdataGiB: 128, isDebugBuild: false)
    )
    await #expect(throws: GlobalSettingsStoreError.unknownSetting(key: "graphics.limits")) {
        try await releaseStore.update(
            ConfigurationPatch(
                patch: .object(["graphics": .object(["limits": .object(["maxDimension": .integer(4096)])])])
            )
        )
    }

    let debugStore = GlobalSettingsStore(
        fileURL: location.file,
        limits: GlobalSettingsStoreLimits(cpuCount: 8, memoryGiB: 12, userdataGiB: 128, isDebugBuild: true)
    )
    let update = try await debugStore.update(
        ConfigurationPatch(
            patch: .object(["graphics": .object(["limits": .object(["maxDimension": .integer(4096)])])])
        )
    )
    #expect(update.changedKeys == ["graphics.limits.maxDimension"])
    #expect(setting("graphics.limits.maxDimension", in: update.snapshot)?.value == .integer(4096))
}
