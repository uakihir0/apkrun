import Foundation
import XCTest

@testable import VirtualMachineCore

final class G1LinuxBootTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["APKRUN_ACCEPTANCE_SUITE"] == "g1" else {
            throw XCTSkip("G1 checks run in the G1 test-plan configuration.")
        }
    }

    func testTenBootsStopThroughTheGuestPowerButton() async throws {
        for bootNumber in 1...10 {
            let result = try await LinuxGuestHarness.run(
                testCase: self,
                stopBehavior: .requestPowerButton,
                powerOff: false
            )
            XCTAssertEqual(result.records.first, .bootOK, "boot \(bootNumber)")
            XCTAssertEqual(result.records.last, .done, "boot \(bootNumber)")
            XCTAssertTrue(
                result.records.contains(
                    .check(
                        name: "powerinput",
                        result: .ok,
                        detail: "PL061 offset 6 line request confirmed"
                    )
                ),
                "power-button monitor armed on boot \(bootNumber)"
            )
            XCTAssertEqual(
                result.states,
                [.stopped, .starting, .running, .stopping, .stopped],
                "boot \(bootNumber)"
            )
        }
    }

    func testFailedStartCanBeReset() async throws {
        let errorInfo = try await LinuxGuestHarness.verifyFailedStartCanReset()

        XCTAssertFalse(errorInfo.domain.isEmpty)
        XCTAssertNotEqual(errorInfo.code, 0)
    }
}
