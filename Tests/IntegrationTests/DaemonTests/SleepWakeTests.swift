import DiagnosticsCore
import Foundation
import RuntimeCore
import XCTest
@testable import RuntimeHost

/// Exercises pause, resume, and guest clock synchronization against Android (#70, runtime-daemon.md §6).
///
/// Runs in the `AndroidSleepWake` test-plan configuration and needs the Android bundle and development Guest Agent.
final class SleepWakeTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-sleep-wake" else {
            throw XCTSkip("Sleep and wake checks run in the AndroidSleepWake test-plan configuration.")
        }
    }

    /// The injected host-sleep event waits for the VM pause; wake resumes the Guest Agent and corrects Android time.
    ///
    /// This uses the same serialized event handler as IOKit and the developer control socket. CI does not force the
    /// Mac itself to sleep, because doing so interrupts the test runner and its VM.
    func testHostSleepPausesAndWakeResumesWithSynchronizedGuestClock() async throws {
        let powerObserver = RuntimeHostPowerObserverHarness()
        try await RuntimeHostBootSession.withBoot(powerObserver: powerObserver) { host, _ in
            let adb = try await Self.connectedClient(host)
            let guestAgentReady = await Self.waitUntil(.seconds(10)) {
                await host.status().guestAgentState == .connected
            }
            XCTAssertTrue(guestAgentReady, "the boot did not start the development Guest Agent")

            let buildType = try await adb.getprop("ro.build.type")
            XCTAssertEqual(buildType, "userdebug", "clock correction relies on the stock userdebug fallback")
            try await adb.restartAsRoot()
            let deliberatelyIncorrectTime = Int64(Date().timeIntervalSince1970.rounded(.down)) - 30
            let skewReply = try await adb.shell("date -u @\(deliberatelyIncorrectTime)", timeout: .seconds(5))
            XCTAssertEqual(skewReply.status, 0, "the test could not set the disposable guest clock")
            let skewedClock = try await Self.guestUnixTime(using: adb)
            XCTAssertLessThanOrEqual(
                abs(skewedClock - deliberatelyIncorrectTime),
                1,
                "the guest clock was not skewed before the resume check"
            )
            let agentReady = await Self.waitUntil(.seconds(10)) {
                await host.status().guestAgentState == .connected
            }
            XCTAssertTrue(agentReady, "the Guest Agent did not recover after the ADB root transition")

            let sleepStartedAt = ContinuousClock.now
            try await powerObserver.send(.systemWillSleep)
            let suspendedAt = ContinuousClock.now
            let pausedState = await host.status().runtimeState
            XCTAssertEqual(pausedState, "suspended", "the host-sleep event must pause Android")
            XCTAssertLessThan(
                sleepStartedAt.duration(to: suspendedAt),
                .seconds(5),
                "the sleep event was not acknowledged within the five-second budget"
            )

            let wakeStartedAt = ContinuousClock.now
            try await powerObserver.send(.systemHasPoweredOn)
            let resumedState = await host.status().runtimeState
            XCTAssertEqual(resumedState, "ready", "the host-wake event must restore readiness")
            let guestTime = try await Self.guestUnixTime(using: adb)
            let wakeToClockCheck = wakeStartedAt.duration(to: ContinuousClock.now)
            XCTAssertLessThan(
                wakeToClockCheck,
                .seconds(5),
                "the runtime did not resume and synchronize the guest within five seconds"
            )

            let hostTime = Date().timeIntervalSince1970
            XCTAssertLessThanOrEqual(
                abs(hostTime - TimeInterval(guestTime)),
                2,
                "the guest wall clock differs from the host by more than two seconds"
            )
        }
    }

    private static func connectedClient(_ host: RuntimeHost) async throws -> AdbClient {
        let boundPort = await host.developmentADBHostPortForTesting()
        let port = try XCTUnwrap(boundPort, "the boot bound no development ADB port")
        let adb = AdbClient(
            executable: try AndroidTestEnvironment.adbExecutable(),
            endpoint: AdbClient.loopbackEndpoint(port: port)
        )
        try await adb.connect(timeout: .seconds(30))
        return adb
    }

    /// Polls a Guest Agent state marker without waiting on a fixed-duration sleep.
    private static func waitUntil(
        _ budget: Duration,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + budget
        while ContinuousClock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }

    /// The stock userdebug image exposes epoch seconds through its standard Android shell `date` command.
    private static func guestUnixTime(using adb: AdbClient) async throws -> Int64 {
        let output = try await adb.shell("date +%s", timeout: .seconds(5)).output
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Int64(value) else {
            throw GuestClockReadFailure.invalidOutput(value)
        }
        return seconds
    }
}

private enum GuestClockReadFailure: Error, CustomStringConvertible {
    case invalidOutput(String)

    var description: String {
        switch self {
        case .invalidOutput(let value):
            "Android date returned an invalid epoch value: \(value)"
        }
    }
}
