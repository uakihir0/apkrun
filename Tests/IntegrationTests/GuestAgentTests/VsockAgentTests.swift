import GuestProtocol
import RuntimeCore
import XCTest

/// T2 Guest Agent channel checks on the APKRun product image (#36, guest-components.md §3–§4).
final class VsockAgentTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try AndroidCustomImageSession.requireAndroidCustomSuite()
    }

    /// The built-in Guest Agent completes the control handshake and serves its token-bound input
    /// and bulk channels through the documented vsock ports, without a development APK install.
    func testControlInputAndBulkChannelsHandshakeOverVsock() async throws {
        try await AndroidCustomImageSession.withBoot(developerMode: false) { session in
            let transport = VsockGuestTransport { port, timeout in
                try await session.supervisor.connect(vsockPort: port, timeout: timeout)
            }
            let control = GuestConnection(endpoint: .guestControl, transport: transport)
            let controlInfo = try await control.open()
            XCTAssertTrue(controlInfo.enabledCapabilities.contains(GuestCapability.core.rawValue))
            let pong = try await control.send(GuestPing(nonce: 6100))
            XCTAssertEqual(pong.nonce, 6100)

            let input = GuestConnection(
                endpoint: .guestInput,
                transport: transport,
                presentedToken: controlInfo.sessionToken
            )
            let inputInfo = try await input.open()
            XCTAssertEqual(inputInfo.agentProtocolVersion, controlInfo.agentProtocolVersion)

            let bulk = GuestConnection(
                endpoint: .guestBulk,
                transport: transport,
                presentedToken: controlInfo.sessionToken
            )
            let bulkInfo = try await bulk.open()
            XCTAssertEqual(bulkInfo.agentProtocolVersion, controlInfo.agentProtocolVersion)

            await bulk.close()
            await input.close()
            await control.close()
        }
    }
}
