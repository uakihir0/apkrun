import Testing

@testable import GuestProtocol

/// A Hello as a fake Guest Agent sends it (guest-protocol.md §5.1).
private func fakeAgentHello(
    major: UInt32 = 1,
    minor: UInt32 = 0,
    channel: GPChannelKind = .guestControl,
    capabilities: [String] = ["core.v1", "display.v1"]
) -> GPHello {
    var version = GPProtocolVersion()
    version.major = major
    version.minor = minor
    var hello = GPHello()
    hello.protocolVersion = version
    hello.channel = channel
    hello.capabilities = capabilities
    return hello
}

private let expectedChannel = GPChannelKind.guestControl

@Test func handshakeAcceptsTheSameMajorVersion() {
    let decision = GuestHandshake.evaluate(fakeAgentHello(), expectedChannel: expectedChannel)
    #expect(
        decision
            == .accepted(
                enabledCapabilities: ["core.v1", "display.v1"],
                agentVersion: ProtocolVersion(major: 1, minor: 0)))
}

@Test func handshakeAcceptsAHigherMinorAndNegotiatesCapabilities() {
    let hello = fakeAgentHello(
        minor: 7, capabilities: ["core.v1", "future.feature.v9", "display.v1"])
    let decision = GuestHandshake.evaluate(hello, expectedChannel: expectedChannel)
    #expect(
        decision
            == .accepted(
                enabledCapabilities: ["core.v1", "display.v1"],
                agentVersion: ProtocolVersion(major: 1, minor: 7)))
}

@Test func handshakeRejectsAFakeAgentSendingMajorTwoWithIncompatibleVersion() {
    let decision = GuestHandshake.evaluate(
        fakeAgentHello(major: 2), expectedChannel: expectedChannel)
    #expect(
        decision
            == .rejected(
                reason: .incompatibleVersion,
                failure: .incompatibleVersion(
                    host: ProtocolVersion(major: 1, minor: 0),
                    guest: ProtocolVersion(major: 2, minor: 0))))
}

@Test func handshakeRejectsAnOlderMajorAsIncompatibleToo() {
    let decision = GuestHandshake.evaluate(
        fakeAgentHello(major: 0, minor: 9), expectedChannel: expectedChannel)
    #expect(
        decision
            == .rejected(
                reason: .incompatibleVersion,
                failure: .incompatibleVersion(
                    host: ProtocolVersion(major: 1, minor: 0),
                    guest: ProtocolVersion(major: 0, minor: 9))))
}

@Test func handshakeRejectsAWrongChannel() {
    let decision = GuestHandshake.evaluate(
        fakeAgentHello(channel: .guestInput), expectedChannel: expectedChannel)
    #expect(
        decision
            == .rejected(
                reason: .wrongChannel, failure: .handshakeFailed(.wrongChannel)))
}

@Test func handshakeTreatsAnUnspecifiedChannelAsAnInvalidHello() {
    let decision = GuestHandshake.evaluate(
        fakeAgentHello(channel: .unspecified), expectedChannel: expectedChannel)
    #expect(decision == .invalid(failure: .handshakeFailed(.invalidHello)))
}

@Test func handshakeTreatsAHelloWithoutAVersionAsAnInvalidHello() {
    var hello = fakeAgentHello()
    hello.clearProtocolVersion()
    let decision = GuestHandshake.evaluate(hello, expectedChannel: expectedChannel)
    #expect(decision == .invalid(failure: .handshakeFailed(.invalidHello)))
}

@Test func handshakeReportsTheVersionBeforeTheChannel() {
    let decision = GuestHandshake.evaluate(
        fakeAgentHello(major: 2, channel: .guestInput), expectedChannel: expectedChannel)
    #expect(
        decision
            == .rejected(
                reason: .incompatibleVersion,
                failure: .incompatibleVersion(
                    host: ProtocolVersion(major: 1, minor: 0),
                    guest: ProtocolVersion(major: 2, minor: 0))))
}
