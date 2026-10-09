package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.ControlSessions
import io.apkrun.guest.protocol.HandshakeFailureReason
import java.io.Closeable

/**
 * The agent's control session and the secondary connections bound to it (guest-protocol.md §5.4).
 * The rules are the ones of [ControlSessions]. This class adds the set of open secondary
 * connections, which close with the control session.
 */
class SessionManager(now: () -> Long) {
    private val sessions = ControlSessions(now)
    private val secondaries = mutableSetOf<Closeable>()

    /** Admits a new control connection, or returns the reason to refuse it. */
    @Synchronized fun admitControl(): HandshakeFailureReason? = sessions.admitControl()

    /** Opens the control session with the token that the host sent in HelloAck. */
    @Synchronized fun openControl(token: ByteArray) = sessions.openControl(token)

    /** Records traffic on the control connection. */
    @Synchronized fun recordControlActivity() = sessions.recordControlActivity()

    /** Admits a secondary connection that presents [token], or returns the reason to refuse it. */
    @Synchronized
    fun admitSecondary(token: ByteArray): HandshakeFailureReason? = sessions.admitSecondary(token)

    /** Tracks an open secondary connection, so that it is closed with the control session. */
    @Synchronized
    fun track(secondary: Closeable) {
        secondaries += secondary
    }

    /** Stops tracking a secondary connection that closed by itself. */
    @Synchronized
    fun untrack(secondary: Closeable) {
        secondaries -= secondary
    }

    /** Closes the control session and every secondary connection of it (guest-protocol.md §5.4). */
    @Synchronized
    fun closeControl() {
        sessions.close()
        val open = secondaries.toList()
        secondaries.clear()
        open.forEach { runCatching { it.close() } }
    }
}
