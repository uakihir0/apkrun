/// The host's decision on the Hello of an agent (guest-protocol.md §5.1, §5.2).
public enum GuestHandshakeDecision: Equatable, Sendable {
    /// The host answers with HelloAck `accepted` and enables these capabilities.
    case accepted(enabledCapabilities: [String], agentVersion: ProtocolVersion)
    /// The host answers with HelloAck `rejected` and closes the connection.
    case rejected(reason: GPRejectReason, failure: GuestProtocolFailure)
    /// The Hello cannot be answered. The host closes the connection without a HelloAck.
    case invalid(failure: GuestProtocolFailure)
}

/// The host side of the handshake, as a pure function of the agent's Hello.
///
/// The agent speaks first, and the host answers (guest-protocol.md §5.1). The host enforces the
/// version and the channel. The session token and the duplicate-session rule belong to the agent,
/// which holds the control session (§5.4).
public enum GuestHandshake {
    /// Judges a Hello on a connection that the host opened for `expectedChannel`.
    ///
    /// The checks run in this order: the Hello must carry a version and a channel, then the major
    /// version must be supported, then the channel must match. Capabilities are negotiated only
    /// for an accepted Hello.
    public static func evaluate(
        _ hello: GPHello,
        expectedChannel: GPChannelKind,
        supportedCapabilities: Set<GuestCapability> = Set(GuestCapability.allCases)
    ) -> GuestHandshakeDecision {
        guard hello.hasProtocolVersion, hello.channel != .unspecified else {
            return .invalid(failure: .handshakeFailed(.invalidHello))
        }
        let agentVersion = ProtocolVersion(hello.protocolVersion)

        switch ProtocolVersion.compatibility(of: agentVersion) {
        case .agentOlder, .agentNewer:
            return .rejected(
                reason: .incompatibleVersion,
                failure: .incompatibleVersion(host: .host, guest: agentVersion))
        case .compatible:
            break
        }

        guard hello.channel == expectedChannel else {
            return .rejected(reason: .wrongChannel, failure: .handshakeFailed(.wrongChannel))
        }

        return .accepted(
            enabledCapabilities: CapabilityNegotiation.enabled(
                advertised: hello.capabilities, supported: supportedCapabilities),
            agentVersion: agentVersion)
    }
}
