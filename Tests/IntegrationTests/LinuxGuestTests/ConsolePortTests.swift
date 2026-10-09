import XCTest

@testable import VirtualMachineCore

final class LinuxGuestConsolePortTests: XCTestCase {
    /// #095 step 1: the marker sent to attachment port `i` arrives on `/dev/hvc<i>`, so the guest numbers
    /// the ports as the host attaches them (vm.md §6.2). The pinned test kernel exposes eight of them.
    func testConsolePortMarkersMatchTheirNumbers() async throws {
        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["ports"],
            consolePortCount: 8,
            extraCommandLine: ["apkrun.test.portcount=8"]
        )

        XCTAssertEqual(result.records.last, .done)
        for index in 1..<8 {
            XCTAssertTrue(
                result.records.contains(
                    .check(name: "port-\(index)", result: .ok, detail: "APKRUN-PORT-\(index)")
                ),
                "port \(index) received its own marker on /dev/hvc\(index)"
            )
        }
    }

    /// #095 step 1 for all 20 ports. The pinned test kernel creates `/dev/hvc0` through `/dev/hvc7` only,
    /// so the check skips when it reaches a missing node. The Android kernel creates `hvc0` through `hvc19`
    /// on the same VZ configuration, and the VZ capture shows their holders (IR-372).
    func testTwentyConsolePorts() async throws {
        do {
            let result = try await LinuxGuestHarness.run(
                testCase: self,
                stopBehavior: .guestPowerOff,
                powerOff: true,
                tests: ["ports"],
                consolePortCount: 20,
                extraCommandLine: ["apkrun.test.portcount=20"]
            )
            XCTAssertEqual(result.records.last, .done)
            for index in 1..<20 {
                XCTAssertTrue(
                    result.records.contains(
                        .check(name: "port-\(index)", result: .ok, detail: "APKRUN-PORT-\(index)")
                    ),
                    "port \(index) received its own marker on /dev/hvc\(index)"
                )
            }
        } catch LinuxGuestHarness.HarnessFailure.guestCheckFailed(let name, let detail)
            where name.hasPrefix("port-") && detail.contains("could not configure /dev/hvc")
        {
            throw XCTSkip(
                "The pinned test kernel creates only /dev/hvc0 through /dev/hvc7 (\(detail)); "
                    + "the Android kernel creates hvc0 through hvc19 (IR-372)."
            )
        }
    }
}
