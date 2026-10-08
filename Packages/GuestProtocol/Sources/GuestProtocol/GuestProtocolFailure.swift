/// The typed failures of the guest protocol, as the host sees them (guest-protocol.md §12.3).
///
/// Codes, messages, and remediations are in error-catalog.md §8. Callers translate the failures
/// that they understand into their own domain.
public enum GuestProtocolFailure: Error, Equatable, Sendable {
    /// The agent's major version is outside ``ProtocolVersion/supportedMajors``. The handshake
    /// fails, and the connection is closed (guest-protocol.md §5.2).
    case incompatibleVersion(host: ProtocolVersion, guest: ProtocolVersion)
    /// The Hello is invalid, or the handshake was rejected for a reason other than the version.
    case handshakeFailed(GuestHandshakeFailureReason)
    /// No Hello arrived within 5 seconds of connecting.
    case handshakeTimedOut
    /// The connection closed while a request was outstanding.
    case disconnected
    /// No response arrived within the timeout of the operation.
    case timeout(operation: String)
    /// The agent answered with a GuestError that the caller does not translate.
    case remote(code: GPGuestErrorCode, message: String, operation: String)
    /// A frame is above the 4 MiB limit. This is a protocol violation.
    case frameTooLarge
    /// Any other protocol violation (guest-protocol.md §12.2).
    case malformedFrame
    /// The agent does not offer a capability that the request needs.
    case capabilityMissing(capability: String)
    /// No connected agent of that kind.
    case agentUnavailable(kind: GuestAgentKind)
}

/// Why the agent's Hello was refused, for the `handshakeFailed` case (guest-protocol.md §5.1, §5.4).
public enum GuestHandshakeFailureReason: Equatable, Sendable {
    /// The Hello is missing a field that the host needs, such as the channel.
    case invalidHello
    /// The agent serves a different channel than the one the host opened.
    case wrongChannel
    /// A secondary connection presented a session token that does not match its control session.
    case badToken
    /// A second control connection arrived while the first one was still active.
    case duplicateSession
}

/// The kind of agent that a connection belongs to.
public enum GuestAgentKind: Equatable, Sendable {
    /// The Guest Agent (`io.apkrun.guest`, `apkrun_guestd`).
    case guestAgent
    /// The Store Agent (`io.apkrun.store`).
    case storeAgent
    /// The development IME, which runs inside the Guest Agent application.
    case guestIME
}
