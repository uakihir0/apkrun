import DiagnosticsCore
import Foundation
import Testing

@testable import RuntimeHost

@Test func runtimeResetClearsBootLoopGuardWithoutStartingAndroidOrClearingStartupFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeReset-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let host = RuntimeHost(
        paths: paths,
        buildInfo: BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "200",
            "APKRunBuildIdentity": "dev",
        ]),
        environment: [:],
        executableURL: root.appendingPathComponent("apkrund")
    )

    try await host.start { ContinuousClock.now }
    let stateStore = DaemonStateStore(fileURL: paths.daemonStateFile)
    let now = Date()
    try stateStore.recordFailedBoot(at: now.addingTimeInterval(-2))
    try stateStore.recordFailedBoot(at: now.addingTimeInterval(-1))
    try stateStore.recordFailedBoot(at: now)
    #expect(try stateStore.bootLoopGuardIsActive())

    let status = try await host.resetRuntime()

    #expect(status.runtimeState == "stopped")
    #expect(!status.crashLoopActive)
    #expect(status.startupFailureCode == "image.noCurrentImage")
    #expect(try stateStore.current()?.recentFailedBoots.isEmpty == true)
    await host.shutdown()
}

@Test func runtimeResetIsANoOpWhenBootLoopGuardIsInactive() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeResetNoOp-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": root.path]
    )
    let host = RuntimeHost(
        paths: paths,
        buildInfo: BuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.2.0",
            "CFBundleVersion": "200",
            "APKRunBuildIdentity": "dev",
        ]),
        environment: [:],
        executableURL: root.appendingPathComponent("apkrund")
    )

    try await host.start { ContinuousClock.now }
    let stateStore = DaemonStateStore(fileURL: paths.daemonStateFile)
    try stateStore.recordFailedBoot(at: Date())

    let status = try await host.resetRuntime()

    #expect(status.runtimeState == "stopped")
    #expect(!status.crashLoopActive)
    #expect(try stateStore.current()?.recentFailedBoots.count == 1)
    await host.shutdown()
}
