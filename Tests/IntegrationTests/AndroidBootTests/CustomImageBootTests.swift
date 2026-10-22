import GuestProtocol
import RuntimeCore
import XCTest

/// T2 boot acceptance for the APKRun AOSP product image (#36).
final class CustomImageBootTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try AndroidCustomImageSession.requireAndroidCustomSuite()
    }

    /// The product image boots with developer mode and ADB disabled while its persistent Guest Agent
    /// answers a versioned protocol handshake and Ping over vsock.
    func testProductImageBootsAndGuestAgentAnswersOverVsockWithAdbOff() async throws {
        try await AndroidCustomImageSession.withBoot(developerMode: false) { session in
            let state = await session.supervisor.state
            XCTAssertEqual(state, .ready)
            let adbPort = await session.supervisor.developmentADBHostPort
            XCTAssertNil(adbPort, "the product image must boot without an ADB forwarder")

            let (connection, info) = try await AndroidCustomImageSession.openAgentConnection(session)
            XCTAssertEqual(info.androidSDKInt, 37)
            XCTAssertEqual(info.agentProtocolVersion, ProtocolVersion(major: 1, minor: 0))
            XCTAssertTrue(info.enabledCapabilities.contains(GuestCapability.core.rawValue))

            let pong = try await connection.send(GuestPing(nonce: 0x36))
            XCTAssertEqual(pong.nonce, 0x36)
            await connection.close()
        }
    }
}
