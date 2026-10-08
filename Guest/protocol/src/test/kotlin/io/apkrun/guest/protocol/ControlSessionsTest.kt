package io.apkrun.guest.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The agent's control session rules (guest-protocol.md §5.4), with a manual clock. */
class ControlSessionsTest {
    private val token = ByteArray(16) { (it * 3).toByte() }
    private var now = 0L
    private val sessions = ControlSessions { now }

    @Test
    fun `a secondary connection that presents the session token is admitted`() {
        sessions.openControl(token)
        assertNull(sessions.admitSecondary(token))
    }

    @Test
    fun `a secondary connection with a different token is refused with BAD_TOKEN`() {
        sessions.openControl(token)
        assertEquals(HandshakeFailureReason.BAD_TOKEN, sessions.admitSecondary(ByteArray(16)))
    }

    @Test
    fun `a secondary connection without a control session is refused with BAD_TOKEN`() {
        assertEquals(HandshakeFailureReason.BAD_TOKEN, sessions.admitSecondary(token))
    }

    @Test
    fun `a second control connection is refused with DUPLICATE_SESSION while the first is active`() {
        sessions.openControl(token)
        now += 10_000
        sessions.recordControlActivity()
        now += 10_000
        assertEquals(HandshakeFailureReason.DUPLICATE_SESSION, sessions.admitControl())
    }

    @Test
    fun `exactly 15 seconds of silence still refuses a second control connection`() {
        sessions.openControl(token)
        now += ControlSessions.SILENCE_LIMIT_MILLIS
        assertEquals(HandshakeFailureReason.DUPLICATE_SESSION, sessions.admitControl())
    }

    @Test
    fun `a second control connection is accepted after more than 15 seconds of silence`() {
        sessions.openControl(token)
        now += ControlSessions.SILENCE_LIMIT_MILLIS + 1
        assertNull(sessions.admitControl())
        assertEquals(false, sessions.isOpen)
    }

    @Test
    fun `a closed control session admits a new control connection at once`() {
        sessions.openControl(token)
        sessions.close()
        assertNull(sessions.admitControl())
    }
}
