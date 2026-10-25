package io.apkrun.guest.daemon.files

import com.google.protobuf.ByteString
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest

/**
 * Streams file contents in bounded chunks and reports the digest of exactly the announced bytes.
 */
internal object ExportFileStreamer {
    fun stream(
        input: InputStream,
        expectedSize: Long,
        sendChunk: (ByteString) -> Unit,
        sendEnd: (ByteString) -> Unit,
    ) {
        if (expectedSize !in 0L..MAXIMUM_FILE_BYTES) {
            throw IOException("the export size is not valid")
        }
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(MAXIMUM_CHUNK_BYTES)
        var remaining = expectedSize
        while (remaining > 0L) {
            val requested = minOf(buffer.size.toLong(), remaining).toInt()
            val count = input.read(buffer, 0, requested)
            if (count < 0) throw IOException("the export source ended before its declared size")
            if (count == 0) continue
            digest.update(buffer, 0, count)
            sendChunk(ByteString.copyFrom(buffer, 0, count))
            remaining -= count
        }
        if (input.read() != -1) {
            throw IOException("the export source changed after its size was announced")
        }
        sendEnd(ByteString.copyFrom(digest.digest()))
    }

    private const val MAXIMUM_CHUNK_BYTES = 1_048_576
    private const val MAXIMUM_FILE_BYTES = 2L * 1024L * 1024L * 1024L
}
