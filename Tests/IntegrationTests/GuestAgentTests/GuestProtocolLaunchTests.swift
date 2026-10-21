import Foundation
import XCTest

/// The display-backed launch path stays off `adb shell` after the Guest Agent is ready (#35 T2).
@MainActor
final class GuestProtocolLaunchTests: XCTestCase {
    private static let helloText = "io.apkrun.fixture.hellotext"
    private static let incrementButtonID = "io.apkrun.fixture.hellotext:id/increment_button"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_INTEGRATION_SUITE"] == "android-guest-protocol-launch" else {
            throw XCTSkip(
                "The Guest Protocol launch acceptance check runs in the AndroidGuestProtocolLaunch test-plan configuration."
            )
        }
    }

    /// The runtime-ready baseline remains unchanged after DevBoot reports the first committed app frame.
    func testHelloTextLaunchDoesNotInvokeAdbShell() async throws {
        guard
            let path = ProcessInfo.processInfo.environment["APKRUN_FIXTURE_APK"],
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("APKRUN_FIXTURE_APK does not name the HelloText fixture APK.")
        }
        let apk = URL(fileURLWithPath: path)

        try await AndroidInputRun.withGuestProtocolLaunch(apk: apk, package: Self.helloText) { run, baseline in
            try await run.waitForAppLaunchFrame()
            try await run.waitForText("Increment")
            let shellInvocationsAfterLaunch = try await run.guestProtocolLaunchAdbShellInvocationCount()

            XCTAssertEqual(
                shellInvocationsAfterLaunch,
                baseline.adbShellInvocationCount,
                "The Guest Protocol launch changed the ADB shell invocation count."
            )
        }
    }

    /// A running display-backed session keeps its task and accepts input after the Guest Agent reconnects.
    func testOpenSessionContinuesAfterAgentReconnect() async throws {
        guard
            let path = ProcessInfo.processInfo.environment["APKRUN_FIXTURE_APK"],
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("APKRUN_FIXTURE_APK does not name the HelloText fixture APK.")
        }
        let apk = URL(fileURLWithPath: path)

        try await AndroidInputRun.withGuestProtocolLaunch(apk: apk, package: Self.helloText) { run, _ in
            try await run.waitForAppLaunchFrame()
            let incrementButton = try await run.centre(of: Self.incrementButtonID)
            guard let sessionBefore = await run.guestProtocolLaunchSessionSnapshot() else {
                return XCTFail("DevBoot did not expose the running app session to the test.")
            }
            XCTAssertEqual(sessionBefore.packageID, Self.helloText)
            XCTAssertEqual(sessionBefore.state, .running)
            XCTAssertFalse(sessionBefore.taskIDs.isEmpty)
            let inputBindingsBeforeReconnect = run.displayZeroInputBindingCount()
            XCTAssertGreaterThan(inputBindingsBeforeReconnect, 0)

            try await run.killGuestAgentAndWaitForReconnect()
            try await run.waitForDisplayZeroInputRebind(after: inputBindingsBeforeReconnect)

            guard let sessionAfter = await run.guestProtocolLaunchSessionSnapshot() else {
                return XCTFail("the display-backed app session disappeared during Guest Agent reconnection.")
            }
            XCTAssertEqual(sessionAfter.id, sessionBefore.id)
            XCTAssertEqual(sessionAfter.state, .running)
            XCTAssertEqual(sessionAfter.taskIDs, sessionBefore.taskIDs)
            try await run.pointer().click(at: incrementButton)
            try await run.waitForText("Count: 1")
        }
    }
}
