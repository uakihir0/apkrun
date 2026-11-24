import Foundation
import RuntimeCore
import XCTest

/// T2 SystemServices resolution against the APKRun product image (#36; guest-components.md §6.2, §12).
final class SystemServicesTest: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try AndroidCustomImageSession.requireAndroidCustomSuite()
    }

    /// Runs the image's platform-signed instrumentation app with `am instrument`. It loads the
    /// production SystemServices classes from the installed Guest Agent and checks the negotiated
    /// capabilities against the methods that resolved on this image.
    func testEverySystemServiceWrapperResolvesOnTheProductImage() async throws {
        try await AndroidCustomImageSession.withBoot(developerMode: true) { session in
            let adb = try await AndroidCustomImageSession.connectedADB(session)
            let reply = try await adb.shell(
                "am instrument -w io.apkrun.guest.systemservicetest/.SystemServicesInstrumentation",
                timeout: .seconds(60)
            )
            XCTAssertEqual(reply.status, 0, reply.output)
            XCTAssertTrue(reply.output.contains("INSTRUMENTATION_CODE: -1"), reply.output)
            XCTAssertEqual(instrumentationResult("wrapper_count", in: reply.output), "8", reply.output)
            XCTAssertEqual(instrumentationResult("missing_method_isolated", in: reply.output), "true", reply.output)

            let reportedWrapperNames =
                (instrumentationResult("wrappers", in: reply.output) ?? "")
                .split(separator: ",")
                .map(String.init)
            let wrapperNames = Set(reportedWrapperNames)
            XCTAssertTrue(
                Set(["display", "window", "activity_task", "activity", "power", "input", "lock_settings"])
                    .isSubset(of: wrapperNames),
                reply.output
            )
            XCTAssertEqual(
                reportedWrapperNames.filter { $0 == "activity_task" || $0 == "activity" }.count,
                3,
                reply.output
            )

            let expectedCapabilities = Set(
                (instrumentationResult("expected_capabilities", in: reply.output) ?? "")
                    .split(separator: ",")
                    .map(String.init)
            )
            let (connection, sessionInfo) = try await AndroidCustomImageSession.openAgentConnection(session)
            await connection.close()
            let enabledCapabilities = Set(sessionInfo.enabledCapabilities)
            XCTAssertTrue(enabledCapabilities.contains("core.v1"), sessionInfo.enabledCapabilities.description)
            for capability in ["display.v1", "launch.v1", "input.v1", "system.v1"] {
                XCTAssertEqual(
                    enabledCapabilities.contains(capability),
                    expectedCapabilities.contains(capability),
                    "\(capability) does not match the methods resolved by instrumentation: \(reply.output)"
                )
            }
        }
    }

    private func instrumentationResult(_ key: String, in output: String) -> String? {
        let prefix = "INSTRUMENTATION_RESULT: \(key)="
        return
            output
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
    }
}
