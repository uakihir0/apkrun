package io.apkrun.guest.daemon.files

import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.BulkAckStatus
import io.apkrun.guest.protocol.v1.BulkBegin
import io.apkrun.guest.protocol.v1.BulkKind
import io.apkrun.guest.protocol.v1.FileRef
import java.security.MessageDigest
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ImportedFileCacheTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun bulkReceiveVerifiesHashAndPersistsPackageScopedContent() {
        val root = temporaryFolder.newFolder("cache")
        var now = 5_000L
        val cache = ImportedFileCache(root) { now }
        val content = "sensitive payload".toByteArray()
        val ref = receive(cache, transferId = 2, name = "report.txt", content = content)

        val shared = cache.claim(listOf(ref), "io.example.viewer").single()

        assertArrayEquals(content, shared.file.readBytes())
        assertNotNull(cache.forProvider(shared.storageId, "io.example.viewer"))
        assertNull(cache.forProvider(shared.storageId, "io.example.other"))

        val restored = ImportedFileCache(root) { now }
        assertArrayEquals(
            content,
            restored.forProvider(shared.storageId, "io.example.viewer")!!.file.readBytes(),
        )
        restored.removePackage("io.example.viewer")
        assertNull(restored.forProvider(shared.storageId, "io.example.viewer"))
    }

    @Test
    fun incompleteOrMismatchedTransfersNeverBecomeReadableFiles() {
        val cache = ImportedFileCache(temporaryFolder.newFolder("cache"))
        val content = "expected".toByteArray()
        val begin = begin("safe.txt", content, digest = ByteArray(32))
        assertNull(cache.begin(2, begin))
        assertNull(cache.append(2, content))
        assertEquals(
            BulkAckStatus.BULK_ACK_STATUS_HASH_MISMATCH,
            cache.end(2, byteArrayOf()),
        )
        assertTrue(temporaryFolder.root.walkTopDown().none { it.extension == "bin" })

        assertNull(cache.begin(4, begin("partial.txt", content)))
        cache.abortIncomplete()
        assertTrue(temporaryFolder.root.walkTopDown().none { it.extension == "part" })
    }

    @Test
    fun limitsTransferCountAndTotalCachedBytesBeforeWriting() {
        val root = temporaryFolder.newFolder("cache")
        val cache = ImportedFileCache(root)
        val empty =
            BulkBegin.newBuilder()
                .setKind(BulkKind.BULK_KIND_FILE)
                .setName("empty.bin")
                .setMimeType("application/octet-stream")
                .setSize(0)
                .setSha256(ByteString.copyFrom(sha256(byteArrayOf())))
                .build()
        repeat(ImportedFileCache.MAXIMUM_ACTIVE_TRANSFERS) { index ->
            assertNull(cache.begin((index + 1L) * 2L, empty))
        }
        assertEquals(
            BulkAckStatus.BULK_ACK_STATUS_REJECTED,
            cache.begin(20, empty),
        )
        cache.abortIncomplete()

        val twoGiB =
            BulkBegin.newBuilder()
                .setKind(BulkKind.BULK_KIND_FILE)
                .setName("large.bin")
                .setMimeType("application/octet-stream")
                .setSize(ImportedFileCache.MAXIMUM_FILE_BYTES)
                .setSha256(ByteString.copyFrom(ByteArray(32)))
                .build()
        assertNull(cache.begin(30, twoGiB))
        assertNull(cache.begin(32, twoGiB))
        assertEquals(
            BulkAckStatus.BULK_ACK_STATUS_TOO_LARGE,
            cache.begin(
                34,
                twoGiB.toBuilder().setName("too-large.bin").setSize(1).build(),
            ),
        )
        cache.abortIncomplete()
    }

    @Test
    fun completedRecordsExpireAfterTwentyFourHours() {
        val root = temporaryFolder.newFolder("cache")
        var now = 10_000L
        val cache = ImportedFileCache(root) { now }
        val ref = receive(cache, transferId = 2, name = "expired.txt", content = byteArrayOf(1))
        val file = cache.claim(listOf(ref), "io.example.viewer").single()
        assertTrue(file.file.exists())

        now += ImportedFileCache.MAXIMUM_AGE_MILLIS
        cache.cleanupExpired()

        assertFalse(file.file.exists())
        assertNull(cache.forProvider(file.storageId, "io.example.viewer"))
    }

    private fun receive(
        cache: ImportedFileCache,
        transferId: Long,
        name: String,
        content: ByteArray,
    ): FileRef {
        val begin = begin(name, content)
        assertNull(cache.begin(transferId, begin))
        if (content.isNotEmpty()) assertNull(cache.append(transferId, content))
        assertEquals(BulkAckStatus.BULK_ACK_STATUS_OK, cache.end(transferId, byteArrayOf()))
        return FileRef.newBuilder()
            .setTransferId(transferId)
            .setName(name)
            .setMimeType(begin.mimeType)
            .setSize(content.size.toLong())
            .build()
    }

    private fun begin(name: String, content: ByteArray, digest: ByteArray = sha256(content)) =
        BulkBegin.newBuilder()
            .setKind(BulkKind.BULK_KIND_FILE)
            .setName(name)
            .setMimeType("text/plain")
            .setSize(content.size.toLong())
            .setSha256(ByteString.copyFrom(digest))
            .build()

    private fun sha256(content: ByteArray) = MessageDigest.getInstance("SHA-256").digest(content)
}
