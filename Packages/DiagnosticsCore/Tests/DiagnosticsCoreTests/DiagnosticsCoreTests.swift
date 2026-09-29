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
    #expect(paths.packageIncomingDirectory(packageID: "org.example.app", ticket: "ticket-1").lastPathComponent == "ticket-1")
    #expect(paths.packageStagedDirectory(packageID: "org.example.app").lastPathComponent == "staged")
    #expect(paths.consoleLogRotationFile(index: 2).lastPathComponent == "console.2.log")
    let recoveryPoint = paths.recoveryPointDirectory(timestamp: "20260929T120000Z", imageVersion: "2026.10.0")
    #expect(recoveryPoint.lastPathComponent == "20260929T120000Z-2026.10.0")
    #expect(paths.recoveryPointPersistentDiskFile(timestamp: "20260929T120000Z", imageVersion: "2026.10.0").lastPathComponent == "persistent.img")
    #expect(paths.recoveryPointUserDataDiskFile(timestamp: "20260929T120000Z", imageVersion: "2026.10.0").lastPathComponent == "userdata.img")
    #expect(paths.recoveryPointInstanceInfoFile(timestamp: "20260929T120000Z", imageVersion: "2026.10.0").lastPathComponent == "instance.json")
}
