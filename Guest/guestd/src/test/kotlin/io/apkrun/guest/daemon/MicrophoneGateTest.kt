package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.FrameReader
import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.SetMicrophoneAccess
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MicrophoneGateTest {

    private class FakeOpsAccess : MicrophoneGate.OpsAccess {
        data class Call(val uid: Int, val packageName: String, val allowed: Boolean)

        val calls = mutableListOf<Call>()

        override fun setRecordAudioMode(uid: Int, packageName: String, allowed: Boolean) {
            calls += Call(uid, packageName, allowed)
        }
    }

    private class FakeRecordingAccess : MicrophoneGate.RecordingAccess {
        var listener: ((Set<String>) -> Unit)? = null

        override fun register(listener: (Set<String>) -> Unit) {
            this.listener = listener
        }

        override fun unregister() {
            listener = null
        }
    }

    private val packageList =
        listOf(
            MicrophoneGate.RecordablePackage(10100, "com.example.a"),
            MicrophoneGate.RecordablePackage(10101, "com.example.b"),
        )

    private fun gate(): Components {
        val output = ByteArrayOutputStream()
        val events = EventBus()
        events.attach(FrameWriter(output))
        val ops = FakeOpsAccess()
        val recording = FakeRecordingAccess()
        val gate =
            MicrophoneGate(
                events,
                ops,
                recording,
                MicrophoneGate.RecordablePackages { packageList },
            )
        return Components(gate, ops, recording, output)
    }

    private data class Components(
        val gate: MicrophoneGate,
        val ops: FakeOpsAccess,
        val recording: FakeRecordingAccess,
        val output: ByteArrayOutputStream,
    )

    private fun events(output: ByteArrayOutputStream): List<Event> {
        val reader = FrameReader(ByteArrayInputStream(output.toByteArray()))
        val events = mutableListOf<Event>()
        while (true) {
            try {
                events += reader.next().event
            } catch (_: EOFException) {
                return events
            }
        }
    }

    @Test
    fun `an allowed package is enabled and every other package is denied`() {
        val (gate, ops, _, _) = gate()
        gate.setAccess(SetMicrophoneAccess.newBuilder().addPackages("com.example.a").build())
        assertEquals(
            listOf(
                FakeOpsAccess.Call(10100, "com.example.a", true),
                FakeOpsAccess.Call(10101, "com.example.b", false),
            ),
            ops.calls,
        )
    }

    @Test
    fun `a package added later is denied until the next push`() {
        val (gate, ops, _, _) = gate()
        gate.setAccess(SetMicrophoneAccess.newBuilder().addPackages("com.example.a").build())
        ops.calls.clear()
        gate.apply()
        assertEquals(
            listOf(
                FakeOpsAccess.Call(10100, "com.example.a", true),
                FakeOpsAccess.Call(10101, "com.example.b", false),
            ),
            ops.calls,
        )
    }

    @Test
    fun `a recording change is published with package IDs only`() {
        val (gate, _, recording, output) = gate()
        gate.start()
        recording.listener?.invoke(setOf("com.example.a"))
        val recordingEvents = events(output).filter { it.hasRecordingChanged() }
        assertEquals(1, recordingEvents.size)
        assertEquals(listOf("com.example.a"), recordingEvents[0].recordingChanged.packagesList)
    }

    @Test
    fun `an unchanged recording set is not republished`() {
        val (gate, _, recording, output) = gate()
        gate.start()
        recording.listener?.invoke(setOf("com.example.a"))
        recording.listener?.invoke(setOf("com.example.a"))
        assertTrue(events(output).none { it.hasRecordingChanged() } == false)
        assertEquals(
            1,
            events(output).count { it.hasRecordingChanged() },
        )
    }
}
