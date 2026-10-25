package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestProtocolFailure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class EnvelopeIdSequenceTest {
    @Test
    fun acceptsIncreasingIdsAfterTheHandshake() {
        val sequence = EnvelopeIdSequence(initialId = 4L)

        sequence.observe(5L)
        sequence.observe(9L)

        assertEquals(9L, sequence.lastId)
    }

    @Test
    fun rejectsDuplicateDecreasingAndZeroIds() {
        for (badId in listOf(4L, 3L, 0L)) {
            val sequence = EnvelopeIdSequence(initialId = 4L)

            assertThrows(GuestProtocolFailure.MalformedFrame::class.java) {
                sequence.observe(badId)
            }
            assertEquals(4L, sequence.lastId)
        }
    }
}
