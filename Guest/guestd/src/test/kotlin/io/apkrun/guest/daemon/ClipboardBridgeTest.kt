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
        var written: Written? = null

        data class Written(
            val text: String,
            val html: String,
            val sensitive: Boolean,
            val imageUri: String?,
        )

        var listeners = mutableListOf<() -> Unit>()

        override fun read() = clip

        /** Resolves a written image URI like an app's `readImage` does on a device. */
        var imageLoader: ((String) -> ByteArray)? = null

        override fun write(text: String, html: String, sensitive: Boolean, imageUri: String?) {
            written = Written(text, html, sensitive, imageUri)
            val image =
                imageUri
                    ?.let { imageLoader?.invoke(it) }
                    ?.let { ClipboardBridge.ImageClip(it, 1, 1) }
            clip = ClipboardBridge.RawClip(text, html, sensitive, image = image)
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

    private fun bridge(
        bulk: ClipboardBridge.BulkImageSender? = null,
        inbound: InboundTransfers? = null,
    ): Triple<ClipboardBridge, FakeClipAccess, ByteArrayOutputStream> {
        val output = ByteArrayOutputStream()
        val events = EventBus()
        events.attach(FrameWriter(output))
        val access = FakeClipAccess()
        return Triple(ClipboardBridge(events, access, bulk, inbound), access, output)
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
        assertEquals(FakeClipAccess.Written("from host", "<b>x</b>", false, null), access.written)
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
        assertEquals(FakeClipAccess.Written("t", "<i>t</i>", true, null), access.written)

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

    @Test
    fun `an image clip is announced after its bulk transfer`() {
        var sentPng: ByteArray? = null
        val bulk = ClipboardBridge.BulkImageSender { png ->
            sentPng = png
            7
        }
        val (bridge, access, output) = bridge(bulk = bulk)
        bridge.start()
        val png = byteArrayOf(1, 2, 3)

        access.clip =
            ClipboardBridge.RawClip(
                "",
                "",
                false,
                image = ClipboardBridge.ImageClip(png, 4, 4),
            )
        access.listeners.toList().forEach { it() }

        val clip = events(output)[0].clipboardChanged
        assertTrue(clip.hasImage())
        assertEquals(7L, clip.image.transferId)
        assertEquals("image/png", clip.image.mimeType)
        assertEquals(4, clip.image.width)
        assertEquals(4, clip.image.height)
        assertEquals(7L % 2, 1L)
        assertTrue(png.contentEquals(sentPng))
    }

    @Test
    fun `a guest image write does not echo back`() {
        val dir =
            java.io.File.createTempFile("inbound", "").let {
                it.delete()
                java.io.File(it.path + ".d").apply { mkdirs() }
            }
        val inbound = InboundTransfers(dir)
        // The bulk frames of transfer 2 arrive on the bulk connection.
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(2)
                .setBegin(
                    io.apkrun.guest.protocol.v1.BulkBegin.newBuilder()
                        .setKind(io.apkrun.guest.protocol.v1.BulkKind.BULK_KIND_CLIPBOARD_IMAGE)
                        .setSize(3)
                )
                .build()
        )
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(2)
                .setChunk(com.google.protobuf.ByteString.copyFrom(byteArrayOf(9, 9, 9)))
                .build()
        )
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(2)
                .setEnd(io.apkrun.guest.protocol.v1.BulkEnd.getDefaultInstance())
                .build()
        )
        val (bridge, access, output) = bridge(inbound = inbound)
        access.imageLoader = { byteArrayOf(9, 9, 9) }
        bridge.start()

        bridge.setClipboard(
            WireClipData.newBuilder()
                .setImage(
                    io.apkrun.guest.protocol.v1.ClipImage.newBuilder()
                        .setMimeType("image/png")
                        .setWidth(3)
                        .setHeight(3)
                        .setTransferId(2)
                )
                .build()
        )
        access.listeners.toList().forEach { it() }

        assertEquals(0, events(output).size)
        assertEquals(
            "content://io.apkrun.guest.files/transfers/in-2",
            access.written?.imageUri,
        )
    }

    @Test
    fun `a missing image transfer still writes the text`() {
        val dir =
            java.io.File.createTempFile("inbound", "").let {
                it.delete()
                java.io.File(it.path + ".d").apply { mkdirs() }
            }
        val (bridge, access, output) = bridge(inbound = InboundTransfers(dir))
        bridge.start()

        bridge.setClipboard(
            WireClipData.newBuilder()
                .setText("still here")
                .setImage(io.apkrun.guest.protocol.v1.ClipImage.newBuilder().setTransferId(4))
                .build()
        )

        assertEquals("still here", access.written?.text)
        assertEquals(null, access.written?.imageUri)
        // The echoed read hashes to the written text, so nothing reports back.
        access.listeners.toList().forEach { it() }
        assertEquals(0, events(output).size)
    }

    @Test
    fun `an inbound transfer reassembles and is taken once`() {
        val dir =
            java.io.File.createTempFile("inbound", "").let {
                it.delete()
                java.io.File(it.path + ".d").apply { mkdirs() }
            }
        val inbound = InboundTransfers(dir)
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(6)
                .setBegin(io.apkrun.guest.protocol.v1.BulkBegin.getDefaultInstance())
                .build()
        )
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(6)
                .setChunk(com.google.protobuf.ByteString.copyFrom(byteArrayOf(1, 2)))
                .build()
        )
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(6)
                .setChunk(com.google.protobuf.ByteString.copyFrom(byteArrayOf(3)))
                .build()
        )
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(6)
                .setEnd(io.apkrun.guest.protocol.v1.BulkEnd.getDefaultInstance())
                .build()
        )

        val file = inbound.take(6)
        assertTrue(file != null)
        assertTrue(byteArrayOf(1, 2, 3).contentEquals(file!!.readBytes()))
        assertEquals(null, inbound.take(6))
    }

    @Test
    fun `an aborted inbound transfer leaves nothing`() {
        val dir =
            java.io.File.createTempFile("inbound", "").let {
                it.delete()
                java.io.File(it.path + ".d").apply { mkdirs() }
            }
        val inbound = InboundTransfers(dir)
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(8)
                .setBegin(io.apkrun.guest.protocol.v1.BulkBegin.getDefaultInstance())
                .build()
        )
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(8)
                .setChunk(com.google.protobuf.ByteString.copyFrom(byteArrayOf(5)))
                .build()
        )
        inbound.accept(
            io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                .setTransferId(8)
                .setAbort(io.apkrun.guest.protocol.v1.BulkAbort.getDefaultInstance())
                .build()
        )

        assertEquals(null, inbound.take(8))
    }
}
