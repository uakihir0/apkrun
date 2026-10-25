package io.apkrun.guest.daemon.files

import android.os.ParcelFileDescriptor
import io.apkrun.guest.daemon.GuestFailure
import io.apkrun.guest.protocol.v1.ExportDecision
import io.apkrun.guest.protocol.v1.ExportFileOffered
import io.apkrun.guest.protocol.v1.ResolveExport
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ExportFileServiceTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun acceptedOfferWaitsForResponseFlushThenStreamsOneBoundedSource() {
        val file = temporaryFolder.newFile("notes.txt")
        val contents = "guest file bytes".toByteArray()
        file.writeBytes(contents)
        val published = CountDownLatch(1)
        val sent = CountDownLatch(1)
        val event = AtomicReference<ExportFileOffered>()
        val actual = AtomicReference<ByteArray>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val service =
            ExportFileService(
                ExportOfferPublisher {
                    event.set(it)
                    published.countDown()
                    true
                },
                scope,
            )
        service.controlConnected(Any())
        service.attachBulkSender { transferId, descriptor, name, mimeType, size ->
            assertEquals(1L, transferId)
            assertEquals("notes.txt", name)
            assertEquals("text/plain", mimeType)
            assertEquals(contents.size.toLong(), size)
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { actual.set(it.readBytes()) }
            sent.countDown()
        }

        val result = CompletableFuture<ExportOutcome>()
        Thread {
            result.complete(
                service.offerAndWait(
                    ExportFileSource(
                        descriptor = open(file),
                        name = "notes.txt",
                        mimeType = "text/plain",
                        size = contents.size.toLong(),
                        sourcePackage = "io.example.editor",
                        displayId = 7,
                    )
                )
            )
        }
            .start()

        assertTrue(published.await(5, TimeUnit.SECONDS))
        val offer = event.get()
        assertEquals(1L, offer.offerId)
        assertEquals("io.example.editor", offer.sourcePackage)
        assertEquals(7, offer.displayId)
        val start =
            service.resolve(
                42,
                ResolveExport.newBuilder()
                    .setOfferId(offer.offerId)
                    .setDecision(ExportDecision.EXPORT_DECISION_ACCEPT)
                    .build(),
            )
        assertTrue(start.hasTransferId())
        assertEquals(1L, start.transferId % 2L)
        assertEquals(1L, sent.count)

        service.responseSent(42)
        assertTrue(sent.await(5, TimeUnit.SECONDS))
        assertArrayEquals(contents, actual.get())
        assertEquals(ExportOutcome.SAVED, result.get(5, TimeUnit.SECONDS))
        scope.cancel()
    }

    @Test
    fun declinedOfferClosesSourceAndReturnsNoTransferID() {
        val file = temporaryFolder.newFile("cancel.txt")
        file.writeText("cancel")
        val published = CountDownLatch(1)
        val event = AtomicReference<ExportFileOffered>()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val service =
            ExportFileService(
                ExportOfferPublisher {
                    event.set(it)
                    published.countDown()
                    true
                },
                scope,
            )
        service.controlConnected(Any())

        val result = CompletableFuture<ExportOutcome>()
        val descriptor = open(file)
        Thread {
            result.complete(
                service.offerAndWait(
                    ExportFileSource(
                        descriptor = descriptor,
                        name = "cancel.txt",
                        mimeType = "text/plain",
                        size = file.length(),
                        sourcePackage = "io.example.editor",
                        displayId = 3,
                    )
                )
            )
        }
            .start()

        assertTrue(published.await(5, TimeUnit.SECONDS))
        val reply =
            service.resolve(
                8,
                ResolveExport.newBuilder()
                    .setOfferId(event.get().offerId)
                    .setDecision(ExportDecision.EXPORT_DECISION_DECLINE)
                    .build(),
            )
        assertFalse(reply.hasTransferId())
        assertEquals(ExportOutcome.DECLINED, result.get(5, TimeUnit.SECONDS))
        assertFalse(descriptor.fileDescriptor.valid())
        scope.cancel()
    }

    @Test
    fun unknownOfferCannotBeAccepted() {
        val service =
            ExportFileService(
                ExportOfferPublisher { true },
                CoroutineScope(SupervisorJob() + Dispatchers.Default),
            )
        assertThrows(GuestFailure::class.java) {
            service.resolve(
                4,
                ResolveExport.newBuilder()
                    .setOfferId(99)
                    .setDecision(ExportDecision.EXPORT_DECISION_ACCEPT)
                    .build(),
            )
        }
    }

    @Test
    fun staleControlDisconnectDoesNotCancelNewSessionOffers() {
        val ownerBeforeTakeover = Any()
        val currentOwner = Any()
        val file = temporaryFolder.newFile("current.txt")
        file.writeText("current")
        val published = CountDownLatch(1)
        val offer = AtomicReference<ExportFileOffered>()
        val result = CompletableFuture<ExportOutcome>()

        val currentService =
            ExportFileService(
                ExportOfferPublisher {
                    offer.set(it)
                    published.countDown()
                    true
                },
                CoroutineScope(SupervisorJob() + Dispatchers.Default),
            )
        currentService.controlConnected(ownerBeforeTakeover)
        currentService.controlConnected(currentOwner)
        Thread {
            result.complete(
                currentService.offerAndWait(
                    ExportFileSource(
                        descriptor = open(file),
                        name = "current.txt",
                        mimeType = "text/plain",
                        size = file.length(),
                        sourcePackage = "io.example.editor",
                        displayId = 1,
                    )
                )
            )
        }
            .start()

        assertTrue(published.await(5, TimeUnit.SECONDS))
        currentService.controlDisconnected(ownerBeforeTakeover)
        assertFalse(result.isDone)
        currentService.resolve(
            12,
            ResolveExport.newBuilder()
                .setOfferId(offer.get().offerId)
                .setDecision(ExportDecision.EXPORT_DECISION_DECLINE)
                .build(),
        )
        assertEquals(ExportOutcome.DECLINED, result.get(5, TimeUnit.SECONDS))
    }

    private fun open(file: File): ParcelFileDescriptor =
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
}
