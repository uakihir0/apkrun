package io.apkrun.guest.protocol

/**
 * The agent's rules for its one control session (guest-protocol.md §5.4).
 *
 * A second control connection is refused with DUPLICATE_SESSION while the open session was active
 * within [SILENCE_LIMIT_MILLIS]. After that silence the old session is closed, and the new one is
 * accepted. A secondary connection must present the token of the control session, or it is refused
 * with BAD_TOKEN. [nowMillis] is injected, so that tests use a manual clock.
 */
class ControlSessions(private val nowMillis: () -> Long) {
    private var token: ByteArray? = null
    private var lastActivityMillis = 0L

    /** Whether a control session is open. */
    val isOpen: Boolean
        get() = token != null

    /**
     * Admits a new control connection. Returns null when it is admitted, or the reason it is
     * refused.
     */
    fun admitControl(): HandshakeFailureReason? {
        if (isOpen && nowMillis() - lastActivityMillis <= SILENCE_LIMIT_MILLIS) {
            return HandshakeFailureReason.DUPLICATE_SESSION
        }
        close()
        return null
    }

    /** Opens the control session with the token from the accepted HelloAck. */
    fun openControl(sessionToken: ByteArray) {
        token = sessionToken.copyOf()
        lastActivityMillis = nowMillis()
    }

    /** Records traffic on the control connection, such as a Ping. */
    fun recordControlActivity() {
        if (isOpen) {
            lastActivityMillis = nowMillis()
        }
    }

    /** Admits a secondary connection that presents [sessionToken]. Returns null when admitted. */
    fun admitSecondary(sessionToken: ByteArray): HandshakeFailureReason? {
        val open = token ?: return HandshakeFailureReason.BAD_TOKEN
        return if (open.contentEquals(sessionToken)) null else HandshakeFailureReason.BAD_TOKEN
    }

    /** Closes the control session. Its secondary connections are closed with it (§5.4). */
    fun close() {
        token = null
    }

    companion object {
        /** A control session silent for longer than this is replaced by a new connection. */
        const val SILENCE_LIMIT_MILLIS = 15_000L
    }
}
