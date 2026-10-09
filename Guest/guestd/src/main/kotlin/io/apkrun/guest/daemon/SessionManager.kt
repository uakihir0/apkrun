package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.ControlSessions
import io.apkrun.guest.protocol.HandshakeFailureReason
import java.io.Closeable

/**
 * The agent's control session and the secondary connections bound to it (guest-protocol.md §5.4).
 * The rules are the ones of [ControlSessions]. This class adds the control connections: a handshake
 * in progress holds the slot, so two handshakes are never both admitted, and a session that is
 * taken over closes its old connection and that connection's secondary connections. Each control
 * connection releases only its own claim, so an old connection that ends late cannot clear the new
 * session.
 */
class SessionManager(now: () -> Long) {
    private val sessions = ControlSessions(now)
    private val secondaries = mutableSetOf<Closeable>()

    /** The control connection whose handshake is in progress, or null. */
    private var handshaking: Closeable? = null

    /** The control connection that holds the open session, or null. */
    private var control: Closeable? = null

    /**
     * Admits the control connection [connection], or returns the reason to refuse it. A handshake
     * that is in progress refuses another one. An active session refuses a new connection, and a
     * silent session is taken over: its connection and its secondary connections are closed first.
     */
    @Synchronized
    fun admitControl(connection: Closeable): HandshakeFailureReason? {
        if (handshaking != null) {
            return HandshakeFailureReason.DUPLICATE_SESSION
        }
        sessions.admitControl()?.let {
            return it
        }
        retire()
        handshaking = connection
        return null
    }

    /**
     * Opens the control session of [connection] with the token from its HelloAck. Returns false
     * when [connection] was not admitted, and the caller then ends it.
     */
    @Synchronized
    fun openControl(connection: Closeable, token: ByteArray): Boolean {
        if (handshaking !== connection) {
            return false
        }
        handshaking = null
        sessions.openControl(token)
        control = connection
        return true
    }

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

    /**
     * Ends the control connection [connection]. It releases its handshake, and when it holds the
     * session, it closes the session and its secondary connections (guest-protocol.md §5.4).
     * Returns true when it held the session, so that the caller resets the state of the session.
     */
    @Synchronized
    fun endControl(connection: Closeable): Boolean {
        if (handshaking === connection) {
            handshaking = null
        }
        if (control !== connection) {
            return false
        }
        control = null
        sessions.close()
        closeSecondaries()
        return true
    }

    /**
     * Closes the session of the previous control connection, and the secondary connections of it.
     */
    private fun retire() {
        val previous = control
        control = null
        sessions.close()
        closeSecondaries()
        previous?.let { runCatching { it.close() } }
    }

    private fun closeSecondaries() {
        val open = secondaries.toList()
        secondaries.clear()
        open.forEach { runCatching { it.close() } }
    }
}
