package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.FrameReader
import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.v1.ClipData as WireClipData
import io.apkrun.guest.protocol.v1.ClipOrigin
import io.apkrun.guest.protocol.v1.Event
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The loop prevention and the limits of the clipboard path (desktop-integration.md §4.3, §4.4). A
 * fake [ClipboardBridge.ClipAccess] stands in for the ClipboardManager.
 */
class ClipboardBridgeTest {

    private class FakeClipAccess : ClipboardBridge.ClipAccess {
        var clip: ClipboardBridge.RawClip? = null
        var written: Triple<String, String, Boolean>? = null
        var listeners = mutableListOf<() -> Unit>()

        override fun read() = clip

        override fun write(text: String, html: String, sensitive: Boolean) {
            written = Triple(text, html, sensitive)
            clip = ClipboardBridge.RawClip(text, html, sensitive)
        }

        override fun addChangeListener(listener: () -> Unit) {
            listeners += listener
        }

        override fun removeChangeListener(listener: () -> Unit) {
            listeners -= listener
        }

        fun notifyClip(text: String, html: String = "", sensitive: Boolean = false) {
            clip = ClipboardBridge.RawClip(text, html, sensitive)
            listeners.toList().forEach { it() }
        }
    }

    private fun bridge(): Triple<ClipboardBridge, FakeClipAccess, ByteArrayOutputStream> {
        val output = ByteArrayOutputStream()
        val events = EventBus()
        events.attach(FrameWriter(output))
        val access = FakeClipAccess()
        return Triple(ClipboardBridge(events, access), access, output)
    }

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
    fun `a clip an app sets is reported as a guest event`() {
        val (bridge, access, output) = bridge()
        bridge.start()

        access.notifyClip("héllo 😀")

        val events = events(output)
        assertEquals(1, events.size)
        val clip = events[0].clipboardChanged
        assertEquals(1L, clip.seq)
        assertEquals(ClipOrigin.CLIP_ORIGIN_GUEST, clip.origin)
        assertEquals("héllo 😀", clip.text)
        assertFalse(clip.truncated)
        assertFalse(clip.sensitive)
    }

    @Test
    fun `a clip the bridge just set does not echo`() {
        val (bridge, access, output) = bridge()
        bridge.start()

        bridge.setClipboard(
            WireClipData.newBuilder().setText("from host").setHtml("<b>x</b>").build()
        )
        // The system fires the listener for the write the bridge just made (the fake mirrors it).
        access.listeners.toList().forEach { it() }

        assertEquals(0, events(output).size)
        assertEquals(Triple("from host", "<b>x</b>", false), access.written)
        assertEquals(1L, bridge.currentSequence())
    }

    @Test
    fun `a different clip after an own write is still reported`() {
        val (bridge, access, output) = bridge()
        bridge.start()
        bridge.setClipboard(WireClipData.newBuilder().setText("from host").build())
        access.listeners.toList().forEach { it() }

        access.notifyClip("user copy")

        val events = events(output)
        assertEquals(1, events.size)
        assertEquals("user copy", events[0].clipboardChanged.text)
        assertEquals(2L, events[0].clipboardChanged.seq)
    }

    @Test
    fun `a clip the same as an earlier own write but not the current echo is reported`() {
        val (bridge, access, output) = bridge()
        bridge.start()
        bridge.setClipboard(WireClipData.newBuilder().setText("same").build())
        access.listeners.toList().forEach { it() }
        access.notifyClip("other")

        access.notifyClip("same")

        val events = events(output)
        assertEquals(2, events.size)
        assertEquals("same", events[1].clipboardChanged.text)
    }

    @Test
    fun `sensitive and html are carried both ways`() {
        val (bridge, access, output) = bridge()
        bridge.start()
        bridge.setClipboard(
            WireClipData.newBuilder().setText("t").setHtml("<i>t</i>").setSensitive(true).build()
        )
        access.listeners.toList().forEach { it() }
        assertEquals(Triple("t", "<i>t</i>", true), access.written)

        access.notifyClip("s", "<i>s</i>", sensitive = true)
        val clip = events(output)[0].clipboardChanged
        assertEquals("<i>s</i>", clip.html)
        assertTrue(clip.sensitive)
    }

    @Test
    fun `an over-limit clip is truncated at a character boundary`() {
        val (bridge, access, output) = bridge()
        bridge.start()
        val text = "é".repeat(ClipboardBridge.TEXT_BYTE_LIMIT / 2 + 1)

        access.notifyClip(text)

        val clip = events(output)[0].clipboardChanged
        assertTrue(clip.truncated)
        assertEquals(ClipboardBridge.TEXT_BYTE_LIMIT, clip.text.toByteArray(Charsets.UTF_8).size)
        assertEquals("é".repeat(ClipboardBridge.TEXT_BYTE_LIMIT / 2), clip.text)
    }

    @Test
    fun `an empty or missing clip publishes nothing`() {
        val (bridge, access, output) = bridge()
        bridge.start()

        access.clip = null
        access.listeners.toList().forEach { it() }

        assertEquals(0, events(output).size)
    }

    @Test
    fun `stop removes the listener`() {
        val (bridge, access, output) = bridge()
        bridge.start()
        bridge.stop()

        access.notifyClip("unheard")

        assertEquals(0, events(output).size)
    }
}
