import Foundation
import Testing

@testable import DiagnosticsCore

@Test func buildInfoDecodesEmbeddedMetadataFromFixturePlist() throws {
    let fixtureURL = try #require(
        Bundle.module.url(forResource: "BuildInfo", withExtension: "plist", subdirectory: "Fixtures")
    )
    let fixtureData = try Data(contentsOf: fixtureURL)
    let propertyList = try PropertyListSerialization.propertyList(from: fixtureData, format: nil)
    let infoDictionary = try #require(propertyList as? [String: Any])
    let info = BuildInfo(infoDictionary: infoDictionary)

    #expect(info.marketingVersion == "2.4.0")
    #expect(info.buildNumber == "20400")
    #expect(info.buildIdentity == "release")
    #expect(info.gitCommit == "0123abc-dirty")
    #expect(info.configuration == .release)
    #expect(!info.usesEmbeddedRuntime)
}

@Test func buildInfoUsesSafeDefaultsForSwiftPMProducts() {
    let info = BuildInfo(infoDictionary: [:])

    #expect(info.marketingVersion == "0.0.0-dev")
    #expect(info.buildNumber == "0")
    #expect(info.buildIdentity == "dev")
    #expect(info.gitCommit == "unknown")
    #expect(!info.usesEmbeddedRuntime)
}

@Test func pathsIgnoreHomeOverrideUnlessCallerOptsIn() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = ["APKRUN_HOME": "~/Library/Testing/APKRun"]
    let paths = APKRunPaths(environment: environment, homeDirectory: home)

    #if DEBUG
        #expect(paths.dataRoot.path == "/Users/example/Library/Application Support/APKRun-Dev")
        #expect(paths.logsRoot.path == "/Users/example/Library/Logs/APKRun-Dev")
        #expect(paths.cachesRoot.path == "/Users/example/Library/Caches/io.apkrun.APKRun-Dev")
    #else
        #expect(paths.dataRoot.path == "/Users/example/Library/Application Support/APKRun")
        #expect(paths.logsRoot.path == "/Users/example/Library/Logs/APKRun")
        #expect(paths.cachesRoot.path == "/Users/example/Library/Caches/io.apkrun.APKRun")
    #endif
}

@Test func pathsHonorExplicitHomeOverrideAndKeepLogsUnderIt() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": "~/Library/Testing/APKRun"],
        homeDirectory: home
    )

    #expect(paths.dataRoot.path == "/Users/example/Library/Testing/APKRun")
    #expect(paths.logsRoot.path == "/Users/example/Library/Testing/APKRun/Logs")
    #expect(paths.cachesRoot.path == "/Users/example/Library/Testing/APKRun/Caches")
    #expect(paths.currentImage.path == "/Users/example/Library/Testing/APKRun/Images/current")
    #expect(paths.packageJournalFile.path == "/Users/example/Library/Testing/APKRun/Packages/journal.jsonl")
    #expect(paths.imageDirectory(version: "2026.10.0").path == "/Users/example/Library/Testing/APKRun/Images/2026.10.0")
    #expect(paths.imageChecksumsFile(version: "2026.10.0").lastPathComponent == "SHA256SUMS")
    #expect(paths.imageInstallStagingDirectory(name: "2026.10.0").lastPathComponent == ".installing-2026.10.0")
    #expect(paths.instanceInfoFile.lastPathComponent == "instance.json")
    #expect(
        paths.packageIncomingDirectory(packageID: "org.example.app", ticket: "ticket-1").lastPathComponent == "ticket-1"
    )
    #expect(paths.packageStagedDirectory(packageID: "org.example.app").lastPathComponent == "staged")
    #expect(paths.consoleLogRotationFile(index: 2).lastPathComponent == "console.2.log")
    let recoveryPoint = paths.recoveryPointDirectory(timestamp: "20260929T120000Z", imageVersion: "2026.10.0")
    #expect(recoveryPoint.lastPathComponent == "20260929T120000Z-2026.10.0")
    #expect(
        paths.recoveryPointPersistentDiskFile(timestamp: "20260929T120000Z", imageVersion: "2026.10.0")
            .lastPathComponent == "persistent.img")
    #expect(
        paths.recoveryPointUserDataDiskFile(timestamp: "20260929T120000Z", imageVersion: "2026.10.0").lastPathComponent
            == "userdata.img")
    #expect(
        paths.recoveryPointInstanceInfoFile(timestamp: "20260929T120000Z", imageVersion: "2026.10.0").lastPathComponent
            == "instance.json")
}

@Test func componentManifestDecodesPackagedComponentsJSON() throws {
    let fixtureURL = try #require(
        Bundle.module.url(forResource: "components", withExtension: "json", subdirectory: "Fixtures")
    )
    let manifest = try JSONDecoder().decode(ComponentManifest.self, from: Data(contentsOf: fixtureURL))

    #expect(manifest.version == "1.2.0")
    #expect(manifest.build == "1200")
    #expect(manifest.channel == "stable")
    #expect(manifest.commit == "89abcde")
    #expect(manifest.runtimeAPI == "1.30")
    #expect(manifest.guestProtocol == "1.1")
    #expect(manifest.dataSchemas["settings.json"] == 1)
    #expect(manifest.agentPlistSHA256.count == 64)
    #expect(manifest.components["devGuestAgentVersionCode"] == "7")
}

@Test func dataSchemasDeclaresEveryOwnedFile() {
    // runtime-maintenance.md §5: every JSON file under the data root has a
    // schema entry. New files join DataSchemas.current with version 1.
    #expect(DataSchemas.current["settings.json"] == 1)
    #expect(DataSchemas.current["Runtime/state.json"] == 1)
    #expect(DataSchemas.current["Runtime/instance/instance.json"] == 1)
    #expect(DataSchemas.current["Packages/journal.jsonl"] == 1)
    #expect(DataSchemas.current["Updates/state.json"] == 1)
    #expect(DataSchemas.current["Updates/history.jsonl"] == 1)
    #expect(DataSchemas.current["Images/update-state.json"] == 1)
}

@Test func schemaMigratorLeavesCurrentFilesUnchanged() throws {
    let migrator = SchemaMigrator()
    for file in ["settings.json"] {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "v1", withExtension: "json",
                subdirectory: "Fixtures/\(file)")
        )
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
        try FileManager.default.copyItem(at: fixture, to: temporary)

        #expect(try migrator.migrate(url: temporary, file: file) == .unchanged(version: 1))
        // An unchanged file is never rewritten: the bytes stay identical.
        #expect(try Data(contentsOf: fixture) == Data(contentsOf: temporary))
    }
}

@Test func schemaMigratorMigratesAnOlderVersionAndKeepsTheOriginal() throws {
    let step: SchemaMigrator.MigrationStep = { object in
        var migrated = object
        migrated["migratedField"] = true
        return migrated
    }
    let migrator = SchemaMigrator(
        steps: ["settings.json": [0: step]],
        current: ["settings.json": 1]
    )
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(
        at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
    try Data(#"{"schemaVersion": 0, "a": 1}"#.utf8).write(to: temporary)

    #expect(try migrator.migrate(url: temporary, file: "settings.json") == .migrated(from: 0, to: 1))
    let result = try JSONSerialization.jsonObject(with: Data(contentsOf: temporary)) as? [String: Any]
    #expect(result?["schemaVersion"] as? Int == 1)
    #expect(result?["migratedField"] as? Bool == true)
    let backup = temporary.deletingLastPathComponent()
        .appendingPathComponent("settings.v0.json")
    #expect(FileManager.default.fileExists(atPath: backup.path))
    #expect(try String(decoding: Data(contentsOf: backup), as: UTF8.self).contains(#""schemaVersion": 0"#))
}

@Test func schemaMigratorRejectsNewerVersionsWithoutWriting() throws {
    let migrator = SchemaMigrator(current: ["settings.json": 1])
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(
        at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
    let original = Data(#"{"schemaVersion": 9, "a": 1}"#.utf8)
    try original.write(to: temporary)

    #expect(throws: MaintenanceFailure.self) {
        try migrator.migrate(url: temporary, file: "settings.json")
    }
    // A newer file is never written.
    #expect(try Data(contentsOf: temporary) == original)
}

@Test func schemaMigratorMigratesJSONLLineByLine() throws {
    let step: SchemaMigrator.MigrationStep = { object in
        var migrated = object
        migrated["extra"] = "x"
        return migrated
    }
    let migrator = SchemaMigrator(
        steps: ["Updates/history.jsonl": [0: step]],
        current: ["Updates/history.jsonl": 1]
    )
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString).appendingPathComponent("history.jsonl")
    try FileManager.default.createDirectory(
        at: temporary.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent()) }
    var jsonl = Data(#"{"v": 0, "a": 1}"#.utf8)
    jsonl.append(0x0A)
    jsonl.append(contentsOf: #"{"v": 1, "b": 2}"#.utf8)
    jsonl.append(0x0A)
    try jsonl.write(to: temporary)

    let outcome = try migrator.migrate(url: temporary, file: "Updates/history.jsonl")
    #expect(outcome == .migrated(from: 0, to: 1))
    let lines = try String(decoding: Data(contentsOf: temporary), as: UTF8.self)
        .split(separator: "\n").map { String($0) }
    #expect(lines.count == 2)
    #expect(lines[0].contains(#""v":1"#) || lines[0].contains(#""v": 1"#))
}
