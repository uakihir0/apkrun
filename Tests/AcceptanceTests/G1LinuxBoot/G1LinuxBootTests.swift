import XCTest
@testable import VirtualMachineCore

final class G1LinuxBootTests: XCTestCase {
    func testTenBootsStopThroughTheGuestPowerButton() async throws {
        for bootNumber in 1...10 {
            let result = try await LinuxGuestHarness.run(
                testCase: self,
                stopBehavior: .requestPowerButton,
                powerOff: false
            )
            XCTAssertEqual(result.records.first, .bootOK, "boot \(bootNumber)")
            XCTAssertEqual(result.records.last, .done, "boot \(bootNumber)")
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
