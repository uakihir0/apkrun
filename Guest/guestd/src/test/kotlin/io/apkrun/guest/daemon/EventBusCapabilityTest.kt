package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.SystemState
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Test

class EventBusCapabilityTest {
    @Test
    fun eventsForUnnegotiatedCapabilitiesAreDroppedWithoutCreatingSequenceGaps() {
        val output = ByteArrayOutputStream()
        val events = EventBus()
        val writer = FrameWriter(output)

        events.attach(writer, emptySet())
        events.publish(GuestCapability.CORE) {
            it.setSystemStateChanged(SystemState.getDefaultInstance())
        }
        events.attach(writer, setOf(GuestCapability.CORE))
        events.publish(GuestCapability.CORE) {
            it.setSystemStateChanged(SystemState.getDefaultInstance())
        }

        val sent = readEvents(output)
        assertEquals(1, sent.size)
        assertEquals(1L, sent.single().seq)
    }

    private fun readEvents(output: ByteArrayOutputStream) =
        FrameReader(ByteArrayInputStream(output.toByteArray())).let { reader ->
            buildList {
                while (true) {
                    try {
                        add(reader.next().event)
                    } catch (_: EOFException) {
                        break
                    }
                }
            }
        }
}
