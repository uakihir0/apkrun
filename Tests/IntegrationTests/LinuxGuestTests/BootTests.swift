import XCTest
@testable import VirtualMachineCore

final class LinuxGuestBootTests: XCTestCase {
    func testBootMarkerAndGuestPowerOff() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true
        )

        XCTAssertEqual(result.records.first, .bootOK)
        XCTAssertEqual(result.records.last, .done)
        XCTAssertEqual(
            result.states,
            [.stopped, .starting, .running, .stopped]
        )
    }

    func testRequestGuestStopAndForcedStop() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .requestPowerButton,
            powerOff: false
        )

        XCTAssertEqual(result.records.first, .bootOK)
        XCTAssertEqual(result.records.last, .done)
        XCTAssertEqual(
            result.states,
            [.stopped, .starting, .running, .stopping, .stopped]
        )
    }

    func testForcedStop() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .forced,
            powerOff: false
        )

        XCTAssertEqual(result.records.first, .bootOK)
        XCTAssertEqual(result.records.last, .done)
        XCTAssertEqual(
            result.states,
            [.stopped, .starting, .running, .stopping, .stopped]
        )
    }

    func testFailedStartCarriesFrameworkDetailsAndCanReset() async throws {
        let errorInfo = try await LinuxGuestHarness.verifyFailedStartCanReset()

        XCTAssertFalse(errorInfo.domain.isEmpty)
        XCTAssertNotEqual(errorInfo.code, 0)
    }
}
