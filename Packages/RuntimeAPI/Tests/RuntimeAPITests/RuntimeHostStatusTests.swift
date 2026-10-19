import Foundation
import Testing

@testable import RuntimeAPI

@Test func guestAgentStatusFieldsAdvanceAPIMinorVersion() {
    #expect(APIVersion.current == APIVersion(major: 1, minor: 1))
}

private func status(
    guestAgentState: GuestAgentConnectionState? = nil,
    guestAgentProtocolVersion: String? = nil
) -> RuntimeHostStatus {
    RuntimeHostStatus(
        hostState: "running",
        runtimeState: "ready",
        bootProgress: nil,
        startupFailureStep: nil,
        startupFailureCode: nil,
        crashLoopActive: false,
        daemonPID: 42,
        imageVersion: "test-image",
        guestAgentState: guestAgentState,
        guestAgentProtocolVersion: guestAgentProtocolVersion
    )
}

@Test func guestAgentConnectionStatesUseNormalizedWireValues() throws {
    let states: [GuestAgentConnectionState] = [
        .notStarted,
        .connecting,
        .connected,
        .reconnecting,
        .unresponsive,
        .unavailable,
        .incompatible,
        .unknown,
    ]
    let values = [
        "notStarted",
        "connecting",
        "connected",
        "reconnecting",
        "unresponsive",
        "unavailable",
        "incompatible",
        "unknown",
    ]

    for (state, value) in zip(states, values) {
        #expect(try JSONEncoder().encode(state) == Data("\"\(value)\"".utf8))
        #expect(try JSONDecoder().decode(GuestAgentConnectionState.self, from: Data("\"\(value)\"".utf8)) == state)
    }
}

@Test func unknownGuestAgentConnectionStatesDecodeToUnknown() throws {
    #expect(
        try JSONDecoder().decode(GuestAgentConnectionState.self, from: Data(#""futureState""#.utf8)) == .unknown
    )
}

@Test func guestAgentStatusFieldsRoundTrip() throws {
    let expected = status(guestAgentState: .connected, guestAgentProtocolVersion: "1.2")
    let data = try JSONEncoder().encode(expected)
    let decoded = try JSONDecoder().decode(RuntimeHostStatus.self, from: data)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(decoded == expected)
    #expect(object["guestAgentState"] as? String == "connected")
    #expect(object["guestAgentProtocolVersion"] as? String == "1.2")
}

@Test func legacyRuntimeHostStatusDecodesWithoutGuestAgentFields() throws {
    let legacyReply = Data(
        #"""
        {
          "hostState": "running",
          "runtimeState": "ready",
          "bootProgress": null,
          "startupFailureStep": null,
          "startupFailureCode": null,
          "crashLoopActive": false,
          "daemonPID": 42,
          "imageVersion": "test-image"
        }
        """#.utf8
    )

    let decoded = try JSONDecoder().decode(RuntimeHostStatus.self, from: legacyReply)

    #expect(decoded == status())
    #expect(decoded.guestAgentState == nil)
    #expect(decoded.guestAgentProtocolVersion == nil)
}

@Test func unavailableGuestAgentObservationOmitsOptionalFields() throws {
    let data = try JSONEncoder().encode(status())
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["guestAgentState"] == nil)
    #expect(object["guestAgentProtocolVersion"] == nil)
}
