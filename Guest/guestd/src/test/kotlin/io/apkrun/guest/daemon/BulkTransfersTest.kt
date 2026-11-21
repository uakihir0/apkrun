package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.FrameWriter
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The bulk sink stack: the newest attached connection sends, detaching it restores the older. */
class BulkTransfersTest {
    @Test
    fun `detaching a newer connection restores the older sink`() {
        val transfers = BulkTransfers()
        val first = ByteArrayOutputStream()
        val second = ByteArrayOutputStream()
        val firstWriter = FrameWriter(first)
        val secondWriter = FrameWriter(second)
        transfers.attach(firstWriter)
        transfers.attach(secondWriter)

        transfers.sendClipboardImage(byteArrayOf(1, 2, 3))
        assertTrue(second.size() > 0)
        assertEquals(0, first.size())

        transfers.detach(secondWriter)
        transfers.sendClipboardImage(byteArrayOf(4, 5, 6))
        assertTrue(first.size() > 0)
    }

    @Test
    fun `a reattached connection wins over an older one`() {
        val transfers = BulkTransfers()
        val first = ByteArrayOutputStream()
        val second = ByteArrayOutputStream()
        val firstWriter = FrameWriter(first)
        val secondWriter = FrameWriter(second)
        transfers.attach(firstWriter)
        transfers.attach(secondWriter)
        transfers.attach(firstWriter)

        transfers.sendClipboardImage(byteArrayOf(1, 2, 3))
        assertTrue(first.size() > 0)
        assertEquals(0, second.size())
    }
}
