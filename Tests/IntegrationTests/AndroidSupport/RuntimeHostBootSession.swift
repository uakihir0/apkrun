import DiagnosticsCore
import Foundation
import ImageCore
import RuntimeCore
import XCTest
@testable import RuntimeHost

/// A real RuntimeHost boot with isolated paths for daemon lifecycle integration tests.
enum RuntimeHostBootSession {
    static func withBoot(
        idleSettings: RuntimeIdleSettings? = nil,
        idleClock: any RuntimeIdleClock = SuspendingRuntimeIdleClock(),
        packageStoreMutationGate: RuntimeHostStoreMutationGate? = nil,
        powerObserver: RuntimeHostPowerObserverHarness? = nil,
        _ body: (RuntimeHost, RuntimeHostPowerObserverHarness?) async throws -> Void
    ) async throws {
        let bundle = try AndroidBootSession.bundleDirectory()
        guard let guestDirectory = AndroidTestEnvironment.current()["APKRUN_GUEST_DIR"],
            !guestDirectory.isEmpty
        else {
            throw XCTSkip("APKRUN_GUEST_DIR is not set. Build the Guest Agent with scripts/build-guest.sh.")
        }
        do {
            _ = try GuestAgentBundle.load(directory: URL(fileURLWithPath: guestDirectory, isDirectory: true))
        } catch {
            throw XCTSkip("The Guest Agent bundle at \(guestDirectory) could not be loaded: \(error.qualifiedCode)")
        }

        let environment = AndroidTestEnvironment.current()
        let run = try VMRunResources.new(environment: environment)
        defer { VMRunResources.removeHomeOrReport(run.home) }

        let images = ImageStore(
            paths: run.paths,
            trust: .standard(),
            diagnostics: .live(paths: run.paths)
        )
        _ = try await images.install(from: .directory(bundle))

        let host = RuntimeHost(
            paths: run.paths,
            buildInfo: BuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "0.2.0",
                "CFBundleVersion": "200",
                "APKRunBuildIdentity": "dev",
                "APKRunConfiguration": "debug",
            ]),
            environment: environment,
            executableURL: URL(fileURLWithPath: "/Applications/APKRun.app/Contents/Helpers/apkrund"),
            adbHostPort: run.adbHostPort,
            idleSettings: idleSettings,
            idleClock: idleClock
        )
        if let packageStoreMutationGate {
            await host.configurePackageStoreMutationGateForTesting {
                await packageStoreMutationGate.hold()
            }
        }
        if let powerObserver {
            await host.configurePowerObserverForTesting { handler in
                RuntimeHostPowerObserverAdapter(handler: handler, harness: powerObserver)
            }
        }

        do {
            try await host.start { ContinuousClock.now }
            try await host.startRuntime(reason: .cli)
            try await body(host, powerObserver)
        } catch {
            await host.shutdown()
            throw error
        }
        await host.shutdown()
    }
}

/// Pauses an install at the package-store mutation boundary for idle-policy integration tests.
actor RuntimeHostStoreMutationGate {
    private(set) var hasEntered = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        hasEntered = true
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Captures the RuntimeHost observer callback without sending real sleep events to the test Mac.
final class RuntimeHostPowerObserverHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: PowerObserver.EventHandler?
    private var storedStartCount = 0
    private var storedStopCount = 0

    var startCount: Int {
        lock.withLock { storedStartCount }
    }

    var stopCount: Int {
        lock.withLock { storedStopCount }
    }

    func start(handler: @escaping PowerObserver.EventHandler) {
        lock.withLock {
            storedStartCount += 1
            storedHandler = handler
        }
    }

    func stop() {
        lock.withLock {
            storedStopCount += 1
            storedHandler = nil
        }
    }

    func send(_ event: PowerObserverEvent) async throws {
        let handler = try XCTUnwrap(
            lock.withLock { storedHandler },
            "RuntimeHost has not registered its power observer"
        )
        await handler(event)
    }
}

private struct RuntimeHostPowerObserverAdapter: RuntimeHostPowerObserver {
    let handler: PowerObserver.EventHandler
    let harness: RuntimeHostPowerObserverHarness

    func start() throws(PowerObserverFailure) {
        harness.start(handler: handler)
    }

    func stop() {
        harness.stop()
    }
}
