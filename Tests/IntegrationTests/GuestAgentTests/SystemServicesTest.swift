import Foundation
import RuntimeCore
import XCTest

/// T2 SystemServices resolution against the APKRun product image (#36; guest-components.md §6.2, §12).
final class SystemServicesTest: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try AndroidCustomImageSession.requireAndroidCustomSuite()
    }

    /// Runs the Guest Agent's own wrapper check inside Android so reflection sees the image's
    /// framework interfaces, then requires every wrapper and required method to resolve.
    func testEverySystemServiceWrapperResolvesOnTheProductImage() async throws {
        try await AndroidCustomImageSession.withBoot(developerMode: true) { session in
            let adb = try await AndroidCustomImageSession.connectedADB(session)
            let reply = try await adb.shell(
                "CLASSPATH=$(pm path io.apkrun.guest | sed 's/^package://') app_process / io.apkrun.guest.daemon.ServiceCheck"
            )
            XCTAssertEqual(reply.status, 0, reply.output)

            let lines = reply.output.split(whereSeparator: \.isNewline).map(String.init)
            let serviceNames = lines.compactMap { line -> String? in
                guard line.hasPrefix("service="),
                    let value = line.split(separator: " ").first
                else {
                    return nil
                }
                return String(value.dropFirst("service=".count))
            }
            let expectedServiceOrders = [
                ["display", "window", "activity_task", "activity", "activity", "power", "input", "lock_settings"],
                ["display", "window", "activity_task", "activity", "activity_task", "power", "input", "lock_settings"],
            ]
            XCTAssertTrue(
                expectedServiceOrders.contains(serviceNames),
                "the service check returned unexpected wrapper identities: \(lines)"
            )
            for line in lines {
                XCTAssertTrue(line.contains("available=true"), "a service wrapper is unavailable: \(line)")
                XCTAssertTrue(line.hasSuffix("missing="), "a required framework method is missing: \(line)")
            }
        }
    }
}
