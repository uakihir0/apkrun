package io.apkrun.guest.daemon

/**
 * The session token of the currently open control connection (guest-protocol.md §5.4). The IME
 * service is instantiated by the framework, so it cannot hold a reference to [SessionManager]; the
 * token lives here instead, and the service's channel validates a presented token against it, as
 * `admitSecondary` does on the daemon's own channels.
 */
object ActiveControlToken {
    @Volatile private var token: ByteArray? = null

    /** Records the token of the opened control session; null clears it. */
    fun set(value: ByteArray?) {
        token = value
    }

    /** Whether [value] is the token of the current control session. */
    fun matches(value: ByteArray): Boolean = token.contentEquals(value)
}
