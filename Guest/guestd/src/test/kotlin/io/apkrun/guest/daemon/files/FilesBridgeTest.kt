package io.apkrun.guest.daemon.files

import com.google.protobuf.ByteString
import io.apkrun.guest.daemon.GuestFailure
import io.apkrun.guest.protocol.v1.BulkAckStatus
import io.apkrun.guest.protocol.v1.BulkBegin
import io.apkrun.guest.protocol.v1.BulkEnd
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.BulkKind
import io.apkrun.guest.protocol.v1.FileRef
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ImportDisposition
import io.apkrun.guest.protocol.v1.ImportFiles
import io.apkrun.guest.protocol.v1.ImportTarget
import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class FilesBridgeTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun sendsSingleFileToPackageOnRequestedDisplay() {
        val platform = FakePlatform(shareTarget = true)
        val bridge = bridge(platform)
        val content = "share me".toByteArray()
        val ref = receive(bridge, 2, "notes.txt", content)

        val result = bridge.import(shareRequest(ref))

        assertEquals(ImportDisposition.IMPORT_DISPOSITION_SHARED, result.disposition)
        assertEquals(1, result.contentUriCount)
        assertTrue(result.getContentUri(0).startsWith("content://io.apkrun.guest.files/shared/"))
        assertEquals("io.example.viewer", platform.sharedPackage)
        assertEquals(7, platform.sharedDisplay)
        assertEquals(listOf("notes.txt"), platform.sharedNames)
        assertFalse(platform.savedContents.isNotEmpty())
        assertFalse(platform.toastShown)
    }

    @Test
    fun usesMultipleShareIntentContractForSeveralFiles() {
        val platform = FakePlatform(shareTarget = true)
        val bridge = bridge(platform)
        val first = receive(bridge, 2, "first.txt", "one".toByteArray())
        val second = receive(bridge, 4, "second.txt", "two".toByteArray())

        val result = bridge.import(shareRequest(first, second))

        assertEquals(ImportDisposition.IMPORT_DISPOSITION_SHARED, result.disposition)
        assertEquals(2, result.contentUriCount)
        assertEquals(listOf("first.txt", "second.txt"), platform.sharedNames)
    }

    @Test
    fun fallsBackToDownloadsAndReportsTheToastWhenNoShareTargetExists() {
        val platform = FakePlatform(shareTarget = false)
        val bridge = bridge(platform)
        val content = "save me".toByteArray()
        val ref = receive(bridge, 2, "download.txt", content)

        val result = bridge.import(shareRequest(ref))

        assertEquals(
            ImportDisposition.IMPORT_DISPOSITION_SAVED_TO_DOWNLOADS,
            result.disposition,
        )
        assertEquals(listOf(content.toList()), platform.savedContents)
        assertEquals(1, result.contentUriCount)
        assertTrue(platform.toastShown)
        assertFalse(platform.savedFiles.single().exists())
    }

    @Test
    fun explicitDownloadsTargetSkipsShareResolution() {
        val platform = FakePlatform(shareTarget = true)
        val bridge = bridge(platform)
        val content = "downloads".toByteArray()
        val ref = receive(bridge, 2, "saved.txt", content)
        val request =
            ImportFiles.newBuilder()
                .setTarget(ImportTarget.IMPORT_TARGET_DOWNLOADS)
                .setDisplayId(0)
                .addFiles(ref)
                .build()

        val result = bridge.import(request)

        assertEquals(ImportDisposition.IMPORT_DISPOSITION_SAVED_TO_DOWNLOADS, result.disposition)
        assertEquals(0, platform.shareTargetChecks)
        assertTrue(platform.toastShown)
    }

    @Test
    fun rejectsUnknownOrMismatchedTransfersAndBadRequests() {
        val platform = FakePlatform(shareTarget = true)
        val bridge = bridge(platform)
        val ref =
            FileRef.newBuilder()
                .setTransferId(2)
                .setName("missing.txt")
                .setMimeType("text/plain")
                .setSize(1)
                .build()

        val missing =
            org.junit.Assert.assertThrows(GuestFailure::class.java) {
                bridge.import(shareRequest(ref))
            }
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, missing.code)

        val duplicate =
            org.junit.Assert.assertThrows(GuestFailure::class.java) {
                bridge.import(shareRequest(ref, ref))
            }
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, duplicate.code)

        val unknownDisplay =
            FilesBridge(
                ImportedFileCache(temporaryFolder.newFolder("other")),
                displayExists = { false },
                platform = platform,
            )
        val displayFailure =
            org.junit.Assert.assertThrows(GuestFailure::class.java) {
                unknownDisplay.import(shareRequest(ref))
            }
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, displayFailure.code)
    }

    @Test
    fun acknowledgesOnlyValidatedBulkTransfers() {
        val platform = FakePlatform(shareTarget = true)
        val bridge = bridge(platform)
        val content = "bytes".toByteArray()
        val begin =
            BulkBegin.newBuilder()
                .setKind(BulkKind.BULK_KIND_FILE)
                .setName("safe.txt")
                .setMimeType("text/plain")
                .setSize(content.size.toLong())
                .setSha256(
                    ByteString.copyFrom(MessageDigest.getInstance("SHA-256").digest(content))
                )
                .build()

        assertEquals(
            null,
            bridge.receive(BulkFrame.newBuilder().setTransferId(2).setBegin(begin).build()),
        )
        assertEquals(
            null,
            bridge.receive(
                BulkFrame.newBuilder()
                    .setTransferId(2)
                    .setChunk(ByteString.copyFrom(content))
                    .build()
            ),
        )
        assertEquals(
            BulkAckStatus.BULK_ACK_STATUS_OK,
            bridge.receive(
                BulkFrame.newBuilder().setTransferId(2).setEnd(BulkEnd.getDefaultInstance()).build()
            ),
        )
        assertEquals(
            BulkAckStatus.BULK_ACK_STATUS_REJECTED,
            bridge.receive(
                BulkFrame.newBuilder()
                    .setTransferId(10)
                    .setChunk(ByteString.copyFrom(content))
                    .build()
            ),
        )
    }

    private fun bridge(platform: FakePlatform) =
        FilesBridge(
            ImportedFileCache(temporaryFolder.newFolder()),
            displayExists = { it == 7 },
            platform = platform,
        )

    private fun receive(
        bridge: FilesBridge,
        transferId: Long,
        name: String,
        content: ByteArray,
    ): FileRef {
        val digest = MessageDigest.getInstance("SHA-256").digest(content)
        val begin =
            BulkBegin.newBuilder()
                .setKind(BulkKind.BULK_KIND_FILE)
                .setName(name)
                .setMimeType("text/plain")
                .setSize(content.size.toLong())
                .setSha256(ByteString.copyFrom(digest))
                .build()
        assertEquals(
            null,
            bridge.receive(
                BulkFrame.newBuilder().setTransferId(transferId).setBegin(begin).build()
            ),
        )
        if (content.isNotEmpty()) {
            assertEquals(
                null,
                bridge.receive(
                    BulkFrame.newBuilder()
                        .setTransferId(transferId)
                        .setChunk(ByteString.copyFrom(content))
                        .build()
                ),
            )
        }
        assertEquals(
            BulkAckStatus.BULK_ACK_STATUS_OK,
            bridge.receive(
                BulkFrame.newBuilder()
                    .setTransferId(transferId)
                    .setEnd(BulkEnd.getDefaultInstance())
                    .build()
            ),
        )
        return FileRef.newBuilder()
            .setTransferId(transferId)
            .setName(name)
            .setMimeType("text/plain")
            .setSize(content.size.toLong())
            .build()
    }

    private fun shareRequest(vararg refs: FileRef) =
        ImportFiles.newBuilder()
            .setTarget(ImportTarget.IMPORT_TARGET_SHARE_TO_PACKAGE)
            .setPackage("io.example.viewer")
            .setDisplayId(7)
            .addAllFiles(refs.toList())
            .build()

    private class FakePlatform(private val shareTarget: Boolean) : FilesBridge.FilesBridgePlatform {
        var shareTargetChecks = 0
        var sharedPackage: String? = null
        var sharedDisplay: Int? = null
        var sharedNames: List<String> = emptyList()
        var savedContents: List<List<Byte>> = emptyList()
        var savedFiles: List<File> = emptyList()
        var toastShown = false

        override fun contentUri(storageId: String): String =
            "content://io.apkrun.guest.files/shared/$storageId"

        override fun hasShareTarget(
            packageName: String,
            files: List<ImportedFileCache.CachedFile>,
        ): Boolean {
            shareTargetChecks++
            return shareTarget
        }

        override fun share(
            packageName: String,
            displayId: Int,
            files: List<ImportedFileCache.CachedFile>,
        ): Boolean {
            sharedPackage = packageName
            sharedDisplay = displayId
            sharedNames = files.map { it.name }
            return true
        }

        override fun saveToDownloads(files: List<ImportedFileCache.CachedFile>): List<String> {
            savedContents = files.map { it.file.readBytes().toList() }
            savedFiles = files.map { it.file }
            return files.indices.map { "content://downloads/$it" }
        }

        override fun showSavedToDownloads() {
            toastShown = true
        }
    }
}
