package io.apkrun.store.store

import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.ArchiveInfo
import io.apkrun.guest.protocol.v1.ArtifactRef
import io.apkrun.guest.protocol.v1.BulkAck
import io.apkrun.guest.protocol.v1.BulkAckStatus
import io.apkrun.guest.protocol.v1.BulkBegin
import io.apkrun.guest.protocol.v1.BulkEnd
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.BulkKind
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InspectArchive
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ArtifactTransferServiceTest {
    private val inspectionDirectory =
        Files.createTempDirectory("apkrun-store-inspect-test").toFile()
    private var currentTimeMillis = 1_000L
    private val service =
        ArtifactTransferService(
            inspectionDirectory = inspectionDirectory,
            inspectArchives = { files ->
                assertTrue(files.isNotEmpty())
                ArchiveInfo.newBuilder().setPackage("com.example.app").build()
            },
            openInstallArtifact = { _, _, _, _, _ ->
                throw AssertionError("install transfers are not used in inspection cache tests")
            },
            maxConcurrentTransfers = 4,
            maxInspectionArtifacts = 2,
            maxInspectionBytes = 4,
            inspectionMaxAgeMillis = 10,
            clockMillis = { currentTimeMillis },
        )

    @After
    fun tearDown() {
        service.closeAll()
        inspectionDirectory.deleteRecursively()
    }

    @Test
    fun boundsCompletedInspectionArtifactsByCount() {
        upload(transferId = 2, data = byteArrayOf(1))
        upload(transferId = 4, data = byteArrayOf(2))
        val rejected = begin(transferId = 6, size = 1)

        assertEquals(BulkAckStatus.BULK_ACK_STATUS_REJECTED, rejected?.status)
    }

    @Test
    fun boundsInspectionArtifactsByAggregateBytesAndReleasesCapacityAfterInspect() {
        upload(transferId = 2, data = byteArrayOf(1, 2, 3))
        val rejected = begin(transferId = 4, size = 2)
        assertEquals(BulkAckStatus.BULK_ACK_STATUS_REJECTED, rejected?.status)

        val result = service.inspect(inspectRequest(2, "base"))
        assertEquals("com.example.app", result.getPackage())

        assertNull(begin(transferId = 4, size = 2))
        service.closeControlSession(CONTROL_SESSION)
    }

    @Test
    fun expiresCompletedInspectionArtifactsBeforeAcceptingMoreCacheUsage() {
        val originalFile = upload(transferId = 2, data = byteArrayOf(1, 2, 3, 4))

        currentTimeMillis += 10
        assertNull(begin(transferId = 4, size = 1))

        assertFalse(originalFile.exists())
        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
            failureOf { service.inspect(inspectRequest(2, "base")) }.code,
        )
        service.closeControlSession(CONTROL_SESSION)
    }

    @Test
    fun cleansResolvedFilesWhenAnInspectArchiveReferenceIsInvalid() {
        val resolvedFile = upload(transferId = 2, data = byteArrayOf(1))
        val request =
            InspectArchive.newBuilder()
                .addArtifacts(ArtifactRef.newBuilder().setTransferId(2).setName("base"))
                .addArtifacts(ArtifactRef.newBuilder().setTransferId(8).setName("missing"))
                .build()

        val failure = failureOf { service.inspect(request) }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, failure.code)
        assertFalse(resolvedFile.exists())
        assertTrue(inspectionDirectory.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun removesStaleCacheFilesAtStartup() {
        val staleDirectory = File(inspectionDirectory, "old")
        assertTrue(staleDirectory.mkdir())
        val staleFile = File(staleDirectory, "leftover.apk")
        assertTrue(staleFile.createNewFile())

        service.cleanupStaleInspectionFiles()

        assertTrue(inspectionDirectory.listFiles().orEmpty().isEmpty())
    }

    @Test
    fun concurrentBeginReservesCapacityBeforeOpeningInstallArtifact() {
        val directory = Files.createTempDirectory("apkrun-store-transfer-limit-test").toFile()
        val firstOpenEntered = CountDownLatch(1)
        val releaseFirstOpen = CountDownLatch(1)
        val openedArtifacts = AtomicInteger()
        val concurrentService =
            ArtifactTransferService(
                inspectionDirectory = directory,
                inspectArchives = { ArchiveInfo.getDefaultInstance() },
                openInstallArtifact = { _, _, _, _, _ ->
                    if (openedArtifacts.incrementAndGet() == 1) {
                        firstOpenEntered.countDown()
                        check(releaseFirstOpen.await(5, TimeUnit.SECONDS)) {
                            "timed out waiting to release the first artifact open"
                        }
                    }
                    InstallArtifactWriter(ByteArrayOutputStream()) { _, _, _ -> }
                },
                maxConcurrentTransfers = 1,
                clockMillis = { 1_000L },
            )
        val workers = Executors.newFixedThreadPool(2)
        val firstBegin =
            workers.submit<BulkAck?> {
                concurrentService.accept(beginFrame(2, "install-1"), CONTROL_SESSION)
            }
        try {
            if (!firstOpenEntered.await(5, TimeUnit.SECONDS)) {
                val firstAck = firstBegin.get(5, TimeUnit.SECONDS)
                throw AssertionError(
                    "the first BEGIN completed before opening the artifact: $firstAck"
                )
            }

            val secondAck =
                workers
                    .submit<BulkAck?> {
                        concurrentService.accept(beginFrame(4, "install-2"), CONTROL_SESSION)
                    }
                    .get(5, TimeUnit.SECONDS)

            assertEquals(BulkAckStatus.BULK_ACK_STATUS_REJECTED, secondAck?.status)
            assertEquals(1, openedArtifacts.get())
            releaseFirstOpen.countDown()
            assertNull(firstBegin.get(5, TimeUnit.SECONDS))
        } finally {
            releaseFirstOpen.countDown()
            runCatching { firstBegin.get(5, TimeUnit.SECONDS) }
            concurrentService.closeAll()
            workers.shutdownNow()
            workers.awaitTermination(5, TimeUnit.SECONDS)
            directory.deleteRecursively()
        }
    }

    private fun upload(transferId: Long, data: ByteArray): File {
        assertNull(begin(transferId, data.size.toLong()))
        assertNull(
            service.accept(
                BulkFrame.newBuilder()
                    .setTransferId(transferId)
                    .setChunk(ByteString.copyFrom(data))
                    .build(),
                CONTROL_SESSION,
            )
        )
        val digest = MessageDigest.getInstance("SHA-256").digest(data)
        val acknowledgement =
            service.accept(
                BulkFrame.newBuilder()
                    .setTransferId(transferId)
                    .setEnd(BulkEnd.newBuilder().setSha256(ByteString.copyFrom(digest)))
                    .build(),
                CONTROL_SESSION,
            )
        assertEquals(BulkAckStatus.BULK_ACK_STATUS_OK, acknowledgement?.status)
        return inspectionDirectory.listFiles()!!.single { it.name.startsWith("$transferId-") }
    }

    private fun beginFrame(transferId: Long, context: String) =
        BulkFrame.newBuilder()
            .setTransferId(transferId)
            .setBegin(
                BulkBegin.newBuilder()
                    .setKind(BulkKind.BULK_KIND_INSTALL_ARTIFACT)
                    .setContext(context)
                    .setName("base.apk")
                    .setSize(1L)
            )
            .build()

    private fun begin(transferId: Long, size: Long) =
        service.accept(
            BulkFrame.newBuilder()
                .setTransferId(transferId)
                .setBegin(
                    BulkBegin.newBuilder()
                        .setKind(BulkKind.BULK_KIND_INSTALL_ARTIFACT)
                        .setContext("inspect")
                        .setName("base")
                        .setSize(size)
                )
                .build(),
            CONTROL_SESSION,
        )

    private fun inspectRequest(transferId: Long, name: String) =
        InspectArchive.newBuilder()
            .addArtifacts(ArtifactRef.newBuilder().setTransferId(transferId).setName(name))
            .build()

    private fun failureOf(action: () -> Unit): StoreFailure =
        try {
            action()
            throw AssertionError("expected StoreFailure")
        } catch (failure: StoreFailure) {
            failure
        }

    private companion object {
        const val CONTROL_SESSION = "control-session"
    }
}
