import DiagnosticsCore
import Foundation
import RuntimeCore
import Testing

@testable import RuntimeHost

@Test(.timeLimit(.minutes(1)))
func runtimeHostRegistersPowerObservationAtStartupAndStopsItAtShutdown() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-runtime-power-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let paths = APKRunPaths(
        allowingHomeOverride: true,
        environment: ["APKRUN_HOME": directory.path]
    )
    let observer = PowerObserverTestHarness()
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
    await host.configurePowerObserverForTesting(
        factory: { handler in
            TestRuntimePowerObserver(handler: handler, harness: observer)
        }
    )

    try await host.start { ContinuousClock.now }
    #expect(observer.startCount == 1)
    let handler = try #require(observer.handler)
    await handler(.systemWillSleep)
    await handler(.systemHasPoweredOn)

    await host.shutdown()
    #expect(observer.stopCount == 1)
}

private final class PowerObserverTestHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStartCount = 0
    private var storedStopCount = 0
    private var storedHandler: PowerObserver.EventHandler?

    var startCount: Int {
        lock.withLock { storedStartCount }
    }

    var stopCount: Int {
        lock.withLock { storedStopCount }
    }

    var handler: PowerObserver.EventHandler? {
        lock.withLock { storedHandler }
    }

    func started(handler: @escaping PowerObserver.EventHandler) {
        lock.withLock {
            storedStartCount += 1
            storedHandler = handler
        }
    }

    func stopped() {
        lock.withLock {
            storedStopCount += 1
            storedHandler = nil
        }
    }
}

private struct TestRuntimePowerObserver: RuntimeHostPowerObserver {
    let handler: PowerObserver.EventHandler
    let harness: PowerObserverTestHarness

    func start() throws(PowerObserverFailure) {
        harness.started(handler: handler)
    }

    func stop() {
        harness.stopped()
    }
}
