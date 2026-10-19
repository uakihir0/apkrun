import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeHost

@Test func daemonStateStoreStartsRunningAndMarksCleanExit() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-state-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DaemonStateStore(fileURL: directory.appendingPathComponent("daemon.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    let assessment = try store.beginRun(pid: 120, version: "0.2.0 (200)", now: now)
    #expect(!assessment.previousExitWasUnclean)
    #expect(!assessment.crashLoopActive)
    #expect(assessment.record.pid == 120)
    #expect(!assessment.record.cleanExit)

    try store.markCleanExit(pid: 120)
    let persisted = try #require(try store.current())
    #expect(persisted.cleanExit)
    #expect(persisted.startedAt == now)
}

@Test func daemonStateStoreDetectsThreeRecentUncleanExits() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-crash-loop-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DaemonStateStore(fileURL: directory.appendingPathComponent("daemon.json"))
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    let first = try store.beginRun(pid: 101, version: "dev", now: start)
    let second = try store.beginRun(pid: 102, version: "dev", now: start.addingTimeInterval(30))
    let third = try store.beginRun(pid: 103, version: "dev", now: start.addingTimeInterval(60))
    let fourth = try store.beginRun(pid: 104, version: "dev", now: start.addingTimeInterval(90))

    #expect(!first.previousExitWasUnclean)
    #expect(second.previousExitWasUnclean)
    #expect(third.previousExitWasUnclean)
    #expect(!third.crashLoopActive)
    #expect(fourth.previousExitWasUnclean)
    #expect(fourth.crashLoopActive)
    #expect(fourth.record.recentUncleanExits.count == 3)
}

@Test func daemonStateStorePreservesBootHistoryAcrossRuns() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-history-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DaemonStateStore(fileURL: directory.appendingPathComponent("daemon.json"))

    _ = try store.beginRun(pid: 105, version: "dev", now: Date(timeIntervalSince1970: 1_800_000_000))
    let boot = DaemonBootHistory(
        recordedAt: Date(timeIntervalSince1970: 1_800_000_010),
        imageVersion: "2026.10.0-cf16373615-arm64",
        kind: "cold",
        phasesMs: ["kernel": 900, "bootCompleted": 21_500]
    )
    try store.appendBootHistory(boot)
    try store.markCleanExit(pid: 105)
    _ = try store.beginRun(
        pid: 106,
        version: "dev",
        now: Date(timeIntervalSince1970: 1_800_000_030)
    )

    #expect(try store.current()?.bootHistory == [boot])
}

@Test func daemonStateStoreClearsCrashGuardForTheCurrentExplicitRun() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-clear-crash-guard-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DaemonStateStore(fileURL: directory.appendingPathComponent("daemon.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    _ = try store.beginRun(pid: 201, version: "dev", now: now)
    _ = try store.beginRun(pid: 202, version: "dev", now: now.addingTimeInterval(30))
    _ = try store.beginRun(pid: 203, version: "dev", now: now.addingTimeInterval(60))
    let guarded = try store.beginRun(pid: 204, version: "dev", now: now.addingTimeInterval(90))
    #expect(guarded.crashLoopActive)

    try store.recordFailedBoot(at: now.addingTimeInterval(91), pid: 204)
    try store.clearBootLoopGuard(pid: 204)
    let current = try #require(try store.current())
    #expect(current.recentUncleanExits.isEmpty)
    #expect(current.recentFailedBoots.isEmpty)
    #expect(current.bootHistory.isEmpty)
}

@Test func daemonStateStoreActivatesGuardForThreeFailedBoots() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-failed-boots-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DaemonStateStore(fileURL: directory.appendingPathComponent("daemon.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    _ = try store.beginRun(pid: 301, version: "dev", now: now)
    try store.recordFailedBoot(at: now.addingTimeInterval(10), pid: 301)
    try store.recordFailedBoot(at: now.addingTimeInterval(20), pid: 301)
    #expect(try !store.bootLoopGuardIsActive(now: now.addingTimeInterval(20)))
    try store.recordFailedBoot(at: now.addingTimeInterval(30), pid: 301)
    #expect(try store.bootLoopGuardIsActive(now: now.addingTimeInterval(30)))
}

@Test func runtimeHostServesStatusWithoutAnInstalledImageAndShutsDownCleanly() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-daemon-host-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": directory.path]
    )
    let host = RuntimeHost(
        paths: paths,
        buildInfo: BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "200",
            "APKRunBuildIdentity": "dev",
        ]),
        environment: [:],
        executableURL: URL(fileURLWithPath: "/Applications/APKRun.app/Contents/Helpers/apkrund")
    )

    try await host.start { ContinuousClock.now }
    let status = await host.status()
    #expect(status.hostState == "degraded")
    #expect(status.runtimeState == "stopped")
    #expect(status.startupFailureStep == 5)
    #expect(status.startupFailureCode == "image.noCurrentImage")
    await host.shutdown()

    let saved = try #require(try DaemonStateStore(fileURL: paths.daemonStateFile).current())
    #expect(saved.cleanExit)
    #expect(saved.version == "0.2.0 (200)")
}
