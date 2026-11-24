import DiagnosticsCore
import Foundation
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test func runtimeRestartStopsBeforeReturningAStartupFailure() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RuntimeRestart-\(UUID().uuidString)", isDirectory: true)
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

    do {
        try await host.restartRuntime(reason: .cli)
        Issue.record("Restart unexpectedly succeeded without an Android image")
    } catch let error as RuntimeHostError {
        guard case .startupFailed(_, let code) = error else {
            Issue.record("Expected the missing-image startup error, got \(error)")
            await host.shutdown()
            return
        }
        #expect(code == "image.noCurrentImage")
    }

    let status = await host.status()
    #expect(status.hostState == "degraded")
    #expect(status.runtimeState == "stopped")
    await host.shutdown()
}

@Test func localePostBootTriggerIsEnqueuedAfterRestartGuardClears() {
    var isRestarting = true
    var didEnqueuePostBoot = false

    LocaleTimeRestartCompletion.finish(
        didRestart: true,
        activePackageLaunches: 0,
        clearRestarting: { isRestarting = false },
        enqueuePostBoot: {
            #expect(!isRestarting)
            didEnqueuePostBoot = true
        }
    )

    #expect(!isRestarting)
    #expect(didEnqueuePostBoot)
}
