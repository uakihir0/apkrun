package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.ControlSessions
import io.apkrun.guest.protocol.HandshakeFailureReason
import java.io.Closeable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A connection that records whether the agent closed it. */
private class FakeConnection : Closeable {
    var closed = false

    override fun close() {
        closed = true
    }
}

class SessionManagerTest {
    private var clock = 0L
    private val sessions = SessionManager { clock }
    private val token = byteArrayOf(1, 2, 3)

    @Test
    fun aSecondControlConnectionIsRefusedWhileTheFirstIsActive() {
        val first = FakeConnection()
        assertNull(sessions.admitControl(first))
        assertTrue(sessions.openControl(first, token))
        clock += 1_000
        assertEquals(
            HandshakeFailureReason.DUPLICATE_SESSION,
            sessions.admitControl(FakeConnection()),
        )
    }

    @Test
    fun aSecondHandshakeIsRefusedWhileTheFirstIsStillNegotiating() {
        assertNull(sessions.admitControl(FakeConnection()))
        assertEquals(
            HandshakeFailureReason.DUPLICATE_SESSION,
            sessions.admitControl(FakeConnection()),
        )
    }

    @Test
    fun aSilentControlSessionIsReplacedAndItsOldConnectionIsClosed() {
        val old = FakeConnection()
        sessions.admitControl(old)
        sessions.openControl(old, token)
        clock += ControlSessions.SILENCE_LIMIT_MILLIS + 1
        val new = FakeConnection()
        assertNull(sessions.admitControl(new))
        assertTrue(old.closed)
        assertFalse(new.closed)
    }

    @Test
    fun theEndOfAReplacedConnectionDoesNotClearTheNewSession() {
        val old = FakeConnection()
        sessions.admitControl(old)
        sessions.openControl(old, token)
        clock += ControlSessions.SILENCE_LIMIT_MILLIS + 1
        val new = FakeConnection()
        sessions.admitControl(new)
        assertTrue(sessions.openControl(new, token))
        assertFalse(sessions.endControl(old))
        assertNull(sessions.admitSecondary(token))
    }

    @Test
    fun aConnectionThatWasNotAdmittedCannotOpenTheSession() {
        sessions.admitControl(FakeConnection())
        assertFalse(sessions.openControl(FakeConnection(), token))
    }

    @Test
    fun aSecondaryConnectionNeedsTheControlToken() {
        val control = FakeConnection()
        assertEquals(HandshakeFailureReason.BAD_TOKEN, sessions.admitSecondary(token))
        sessions.admitControl(control)
        sessions.openControl(control, token)
        assertEquals(HandshakeFailureReason.BAD_TOKEN, sessions.admitSecondary(byteArrayOf(9)))
        assertNull(sessions.admitSecondary(token))
    }

    @Test
    fun endingTheControlSessionClosesItsSecondaryConnections() {
        val control = FakeConnection()
        sessions.admitControl(control)
        sessions.openControl(control, token)
        val closed = mutableListOf<String>()
        sessions.track(Closeable { closed += "input" })
        sessions.track(Closeable { closed += "bulk" })
        assertTrue(sessions.endControl(control))
        assertEquals(setOf("input", "bulk"), closed.toSet())
        assertEquals(HandshakeFailureReason.BAD_TOKEN, sessions.admitSecondary(token))
    }
}
