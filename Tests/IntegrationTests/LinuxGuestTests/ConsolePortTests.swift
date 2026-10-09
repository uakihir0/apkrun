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
            where name.hasPrefix("port-") && Self.isMissingConsoleNode(detail)
        {
            throw XCTSkip(
                "The pinned test kernel creates only /dev/hvc0 through /dev/hvc7 (\(detail)); "
                    + "the Android kernel creates hvc0 through hvc19 (IR-372)."
            )
        }
    }

    /// Whether the guest reported a console node that does not exist (`/dev/hvc<n>` is absent from its
    /// device list), rather than a node that exists but could not be configured.
    static func isMissingConsoleNode(_ detail: String) -> Bool {
        guard let range = detail.range(of: #"could not configure /dev/hvc(\d+)"#, options: .regularExpression),
            let number = detail[range].split(separator: "hvc").last
        else {
            return false
        }
        let devices =
            detail.components(separatedBy: "devices: ").last?
            .components(separatedBy: ";").first ?? ""
        return !devices.split(separator: " ").contains("hvc\(number)")
    }

    /// The skip is only for a node the guest does not have; a node that exists and fails stays a failure.
    func testMissingNodeDetectionSkipsOnlyAbsentNodes() {
        let absent =
            "could not configure /dev/hvc8; devices: hvc0 hvc1 hvc2 hvc3 hvc4 hvc5 hvc6 hvc7 ; kernel: [x]"
        let present = "could not configure /dev/hvc3; devices: hvc0 hvc1 hvc2 hvc3 hvc4 ; kernel: [x]"
        XCTAssertTrue(Self.isMissingConsoleNode(absent))
        XCTAssertFalse(Self.isMissingConsoleNode(present))
        XCTAssertFalse(Self.isMissingConsoleNode("no host marker arrived on /dev/hvc8"))
    }
}
