package io.apkrun.guest.daemon.files

import com.google.protobuf.ByteString
import java.io.ByteArrayInputStream
import java.io.IOException
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ExportFileStreamerTest {
    @Test
    fun streamsAtMostOneMiBPerChunkAndHashesExactContents() {
        val content = ByteArray(MAXIMUM_CHUNK_BYTES + 1) { (it % 251).toByte() }
        val chunks = mutableListOf<ByteString>()
        var digest: ByteString? = null

        ExportFileStreamer.stream(
            ByteArrayInputStream(content),
            content.size.toLong(),
            sendChunk = chunks::add,
            sendEnd = { digest = it },
        )

        assertEquals(listOf(MAXIMUM_CHUNK_BYTES, 1), chunks.map(ByteString::size))
        assertTrue(chunks.all { it.size() <= MAXIMUM_CHUNK_BYTES })
        assertEquals(
            ByteString.copyFrom(MessageDigest.getInstance("SHA-256").digest(content)),
            digest,
        )
    }

    @Test
    fun rejectsContentShorterThanAnnouncedSize() {
        assertThrows(IOException::class.java) {
            ExportFileStreamer.stream(ByteArrayInputStream(byteArrayOf(1)), 2, {}, {})
        }
    }

    @Test
    fun rejectsContentLongerThanAnnouncedSize() {
        assertThrows(IOException::class.java) {
            ExportFileStreamer.stream(ByteArrayInputStream(byteArrayOf(1, 2)), 1, {}, {})
        }
    }

    private companion object {
        const val MAXIMUM_CHUNK_BYTES = 1_048_576
    }
}
