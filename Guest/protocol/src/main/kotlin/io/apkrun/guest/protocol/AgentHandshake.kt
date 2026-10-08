package io.apkrun.guest.protocol

import io.apkrun.guest.protocol.v1.HelloAck
import io.apkrun.guest.protocol.v1.RejectReason

/** The result of an accepted handshake, from the agent's side (guest-protocol.md §5.1). */
data class AcceptedHandshake(
    val hostVersion: ProtocolVersion,
    val sessionToken: ByteArray,
    val enabledCapabilities: List<String>,
) {
    override fun equals(other: Any?): Boolean =
        other is AcceptedHandshake &&
            hostVersion == other.hostVersion &&
            sessionToken.contentEquals(other.sessionToken) &&
            enabledCapabilities == other.enabledCapabilities

    override fun hashCode(): Int =
        listOf(hostVersion, sessionToken.contentHashCode(), enabledCapabilities).hashCode()
}

/**
 * The agent's side of the handshake (guest-protocol.md §5.1, §5.2). The agent sends Hello first,
 * and the host answers with HelloAck. [evaluate] turns that answer into an accepted handshake or a
 * typed [GuestProtocolFailure].
 */
object AgentHandshake {
    /**
     * Judges the HelloAck that the host sent. A rejection becomes the failure of its reason. An
     * accepted HelloAck is checked for a supported host major version, and then its capabilities
     * are narrowed to the ones this agent implements.
     */
    fun evaluate(
        ack: HelloAck,
        agentVersion: ProtocolVersion = ProtocolVersion.HOST,
        implemented: Set<GuestCapability> = GuestCapability.entries.toSet(),
    ): AcceptedHandshake {
        // HelloAck carries either accepted or rejected. A HelloAck with neither is a protocol
        // violation (§12.2), so it fails before any of its fields are trusted.
        if (ack.outcomeCase == HelloAck.OutcomeCase.OUTCOME_NOT_SET) {
            throw GuestProtocolFailure.MalformedFrame(
                "the HelloAck has neither accepted nor rejected"
            )
        }
        if (ack.hasRejected()) {
            throw failure(ack, agentVersion, ack.rejected.reason)
        }
        if (!ack.hasHostProtocolVersion()) {
            throw GuestProtocolFailure.MalformedFrame("the HelloAck has no host version")
        }
        val host = ProtocolVersion(ack.hostProtocolVersion.major, ack.hostProtocolVersion.minor)
        if (ProtocolVersion.compatibility(host) != ProtocolCompatibility.COMPATIBLE) {
            throw GuestProtocolFailure.IncompatibleVersion(host, agentVersion)
        }
        return AcceptedHandshake(
            hostVersion = host,
            sessionToken = ack.sessionToken.toByteArray(),
            enabledCapabilities = GuestCapability.enabled(ack.enabledCapabilitiesList, implemented),
        )
    }

    private fun failure(
        ack: HelloAck,
        agentVersion: ProtocolVersion,
        reason: RejectReason,
    ): GuestProtocolFailure =
        when (reason) {
            RejectReason.REJECT_REASON_INCOMPATIBLE_VERSION ->
                GuestProtocolFailure.IncompatibleVersion(
                    ProtocolVersion(ack.hostProtocolVersion.major, ack.hostProtocolVersion.minor),
                    agentVersion,
                )
            RejectReason.REJECT_REASON_WRONG_CHANNEL ->
                GuestProtocolFailure.HandshakeFailed(HandshakeFailureReason.WRONG_CHANNEL)
            RejectReason.REJECT_REASON_BAD_TOKEN ->
                GuestProtocolFailure.HandshakeFailed(HandshakeFailureReason.BAD_TOKEN)
            RejectReason.REJECT_REASON_DUPLICATE_SESSION ->
                GuestProtocolFailure.HandshakeFailed(HandshakeFailureReason.DUPLICATE_SESSION)
            RejectReason.REJECT_REASON_UNSPECIFIED,
            RejectReason.UNRECOGNIZED ->
                GuestProtocolFailure.HandshakeFailed(HandshakeFailureReason.INVALID_HELLO)
        }
}
