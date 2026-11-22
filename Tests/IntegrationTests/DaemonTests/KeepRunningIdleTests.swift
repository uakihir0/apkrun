import Foundation
import RuntimeAPI
import RuntimeCore
import XCTest

@testable import RuntimeHost

/// Exercises `window.closeBehavior = keepRunning` against a running Android VM
/// (#116, display-and-windowing.md §7.6): a task a keepRunning close retains
/// holds a `.backgroundTask` activity assertion until it ends.
///
/// Runs in the `AndroidCustomKeepRunning` test-plan configuration and needs the
/// Android bundle and development Guest Agent.
final class KeepRunningIdleTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"]
            == "android-keep-running-idle"
        else {
            throw XCTSkip(
                "KeepRunning checks run in the AndroidCustomKeepRunning test-plan configuration."
            )
        }
    }

    /// A keepRunning close releases the `.session` hold but keeps the runtime
    /// awake through `.backgroundTask`; terminating the package then drops the
    /// hold and the idle suspend deadline applies again.
    func testRetainedTaskHoldsRuntimeUntilTermination() async throws {
        guard let fixturePath = AndroidTestEnvironment.current()["APKRUN_FIXTURE_APK"],
            !fixturePath.isEmpty,
            FileManager.default.fileExists(atPath: fixturePath)
        else {
            throw XCTSkip("APKRUN_FIXTURE_APK does not name the HelloText fixture.")
        }
        let packageID = try XCTUnwrap(RuntimePackageID(rawValue: "io.apkrun.fixture.hellotext"))

        let clock = ManualRuntimeIdleClock()
        try await RuntimeHostBootSession.withBoot(
            idleSettings: try RuntimeIdleSettings(idleSuspendMinutes: 1, idleStopMinutes: 0),
            idleClock: clock
        ) { host, _ in
            let guestAgentReady = await Self.waitUntil(.seconds(15)) {
                await host.status().guestAgentState == .connected
            }
            XCTAssertTrue(guestAgentReady, "the internal ADB connection did not start the Guest Agent")

            try await Self.installHelloText(at: URL(fileURLWithPath: fixturePath), on: host)
            let storeActivityReleased = await Self.waitUntil(.seconds(5)) {
                !(await host.idleActivityKindsForTesting().contains(.storeOperation))
            }
            XCTAssertTrue(storeActivityReleased, "installing HelloText kept its store activity assertion")

            let launch = try await host.launch(RuntimeLaunchRequest(packageID: packageID))
            XCTAssertEqual(launch.state, .running, "HelloText did not reach the running state")

            let closed = try await host.closeSession(
                RuntimeCloseSessionRequest(packageID: packageID, policy: .keepRunning))
            XCTAssertTrue(closed.hadSession, "keepRunning close found no session")

            let sessionReleased = await Self.waitUntil(.seconds(5)) {
                !(await host.idleActivityKindsForTesting().contains(.session))
            }
            XCTAssertTrue(sessionReleased, "the keepRunning close kept the session activity hold")
            let backgroundHeld = await Self.waitUntil(.seconds(5)) {
                await host.idleActivityKindsForTesting().contains(.backgroundTask)
            }
            XCTAssertTrue(backgroundHeld, "the retained task did not hold a backgroundTask assertion")

            clock.advanceAwakeTime(by: .seconds(61))
            let stayedReady = await Self.waitUntil(.seconds(5)) {
                await host.status().runtimeState == "ready"
            }
            XCTAssertTrue(stayedReady, "the runtime suspended while a keepRunning task was retained")

            _ = try await host.terminate(RuntimeTerminateRequest(packageID: packageID))
            let backgroundReleased = await Self.waitUntil(.seconds(5)) {
                !(await host.idleActivityKindsForTesting().contains(.backgroundTask))
            }
            XCTAssertTrue(backgroundReleased, "terminating the package kept the backgroundTask hold")

            clock.advanceAwakeTime(by: .seconds(61))
            let suspended = await Self.waitUntil(.seconds(5)) {
                await host.status().runtimeState == "suspended"
            }
            XCTAssertTrue(suspended, "the runtime did not suspend once the retained task ended")
        }
    }

    private static func installHelloText(at apk: URL, on host: RuntimeHost) async throws {
        let file = try FileHandle(forReadingFrom: apk)
        defer { try? file.close() }
        let preview = try await host.importPackage(
            RuntimeImportPackageRequest(
                files: [RuntimeImportSourceFile(fileIndex: 0, name: apk.lastPathComponent)],
                origin: .cli
            ),
            files: [file]
        )
        _ = try await host.installImported(RuntimeInstallImportedRequest(ticket: preview.ticket))
    }

    private static func waitUntil(
        _ timeout: Duration,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await condition()
    }
}
