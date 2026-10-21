package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.SystemState
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Test

class SystemStateMonitorTest {
    @Test
    fun stateEventsFollowSnapshotAndOnlyReportChanges() {
        val output = ByteArrayOutputStream()
        val events = EventBus().apply { attach(FrameWriter(output)) }
        var current = SystemState.newBuilder().setBootCompleted(false).build()
        var onChange: (() -> Unit)? = null
        val monitor =
            SystemStateMonitor(events, { current }) {
                onChange = it
            }

        monitor.start()
        onChange?.invoke()
        current = current.toBuilder().setBootCompleted(true).build()
        onChange?.invoke()

        val stateEvents =
            FrameReader(ByteArrayInputStream(output.toByteArray())).let { reader ->
                buildList {
                    while (true) {
                        try {
                            add(reader.next().event.systemStateChanged)
                        } catch (_: EOFException) {
                            break
                        }
                    }
                }
            }
        assertEquals(listOf(current), stateEvents)
    }
}
