package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.ControlSessions
import io.apkrun.guest.protocol.HandshakeFailureReason
import java.io.Closeable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SessionManagerTest {
    private var clock = 0L
    private val sessions = SessionManager { clock }
    private val token = byteArrayOf(1, 2, 3)

    @Test
    fun aSecondControlConnectionIsRefusedWhileTheFirstIsActive() {
        assertNull(sessions.admitControl())
        sessions.openControl(token)
        clock += 1_000
        assertEquals(HandshakeFailureReason.DUPLICATE_SESSION, sessions.admitControl())
    }

    @Test
    fun aSilentControlSessionIsReplacedAfterFifteenSeconds() {
        sessions.openControl(token)
        clock += ControlSessions.SILENCE_LIMIT_MILLIS + 1
        assertNull(sessions.admitControl())
    }

    @Test
    fun aSecondaryConnectionNeedsTheControlToken() {
        assertEquals(HandshakeFailureReason.BAD_TOKEN, sessions.admitSecondary(token))
        sessions.openControl(token)
        assertEquals(HandshakeFailureReason.BAD_TOKEN, sessions.admitSecondary(byteArrayOf(9)))
        assertNull(sessions.admitSecondary(token))
    }

    @Test
    fun closingTheControlSessionClosesItsSecondaryConnections() {
        sessions.openControl(token)
        val closed = mutableListOf<String>()
        sessions.track(Closeable { closed += "input" })
        sessions.track(Closeable { closed += "bulk" })
        sessions.closeControl()
        assertEquals(setOf("input", "bulk"), closed.toSet())
        assertEquals(HandshakeFailureReason.BAD_TOKEN, sessions.admitSecondary(token))
    }
}
