package io.apkrun.guest.protocol

/** The typed failures of the guest protocol, as the agent sees them (guest-protocol.md §12.3). */
sealed class GuestProtocolFailure(message: String) : RuntimeException(message) {
    /** A frame is above the 4 MiB limit. This is a protocol violation (§4). */
    class FrameTooLarge : GuestProtocolFailure("a frame is above the 4 MiB limit")

    /**
     * Any other protocol violation (§12.2): a zero length, a body that does not decode, and so on.
     */
    class MalformedFrame(detail: String) : GuestProtocolFailure("malformed frame: $detail")

    /** The host's major version is outside [ProtocolVersion.SUPPORTED_MAJORS] (§5.2). */
    class IncompatibleVersion(val host: ProtocolVersion, val guest: ProtocolVersion) :
        GuestProtocolFailure("protocol version $host is not supported by guest $guest")

    /** The handshake was refused, or a session rule failed (§5.1, §5.4). */
    class HandshakeFailed(val reason: HandshakeFailureReason) :
        GuestProtocolFailure("handshake failed: $reason")
}

/** Why a handshake or a session rule failed, for [GuestProtocolFailure.HandshakeFailed]. */
enum class HandshakeFailureReason {
    INVALID_HELLO,
    WRONG_CHANNEL,
    BAD_TOKEN,
    DUPLICATE_SESSION,
}
