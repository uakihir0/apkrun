import GuestProtocol
import RuntimeCore
import XCTest

/// T2 policy audit for the custom product domains (#36; guest-components.md §4.2, §10.2).
final class SelinuxDenialTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try AndroidCustomImageSession.requireAndroidCustomSuite()
    }

    /// Exercise the built-in Guest Agent through vsock, then verify its domain and the bridge
    /// domain generated no AVC denials during a clean product boot.
    func testGuestAgentAndVsockBridgeHaveNoAvcDenials() async throws {
        try await AndroidCustomImageSession.withBoot(developerMode: true) { session in
            let (connection, _) = try await AndroidCustomImageSession.openAgentConnection(session)
            let pong = try await connection.send(GuestPing(nonce: 3610))
            XCTAssertEqual(pong.nonce, 3610)
            await connection.close()

            let adb = try await AndroidCustomImageSession.connectedADB(session)
            try await adb.restartAsRoot()
            let denials = try await adb.dmesg()
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter {
                    $0.contains("avc: denied")
                        && ($0.contains("scontext=u:r:apkrun_guest_app")
                            || $0.contains("scontext=u:r:apkrun_vsockd"))
                }
            XCTAssertTrue(denials.isEmpty, "the custom agent domains emitted AVC denials: \(denials)")
        }
    }
}
