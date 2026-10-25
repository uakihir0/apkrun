package io.apkrun.store.store

import io.apkrun.guest.protocol.FrameCodec
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.PackageChangeKind
import io.apkrun.guest.protocol.v1.PackageChanged
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StoreFramesTest {
    @Test
    fun packageEventsDoNotWaitForSocketWritesAndKeepTheirFrameOrder() {
        val output = BlockingOutputStream(expectedWrites = 3)
        val writer = StoreFrameWriter(output, eventQueueCapacity = 2)
        val events = StoreEventBus()
        events.attach(writer, setOf(StoreDispatcher.STORE_METADATA_CAPABILITY))

        try {
            events.publishPackageChanged(1)
            assertTrue(output.writeStarted.await(1, TimeUnit.SECONDS))

            // These package broadcasts must return while the first socket write is still blocked.
            events.publishPackageChanged(2)
            events.publishPackageChanged(3)

            output.allowWrites.countDown()
            assertTrue(output.expectedWrites.await(1, TimeUnit.SECONDS))

            val envelopes = output.frames.map(FrameCodec::decode)
            assertEquals(listOf(1L, 2L, 3L), envelopes.map { it.id })
            assertEquals(listOf(1L, 2L, 3L), envelopes.map { it.event.seq })
            assertTrue(
                envelopes.all { it.bodyCase == io.apkrun.guest.protocol.v1.Envelope.BodyCase.EVENT }
            )
        } finally {
            output.allowWrites.countDown()
            writer.close()
        }
    }

    @Test
    fun fullEventQueueClosesTheControlConnectionAndRejectsLaterEvents() {
        val output = BlockingOutputStream(expectedWrites = 1)
        val connectionClosed = CountDownLatch(1)
        val closeCalls = AtomicInteger()
        val writer =
            StoreFrameWriter(
                output,
                closeConnection = {
                    closeCalls.incrementAndGet()
                    connectionClosed.countDown()
                },
                eventQueueCapacity = 1,
            )
        val events = StoreEventBus()
        events.attach(writer, setOf(StoreDispatcher.STORE_METADATA_CAPABILITY))

        try {
            events.publishPackageChanged(1)
            assertTrue(output.writeStarted.await(1, TimeUnit.SECONDS))
            events.publishPackageChanged(2) // occupies the one waiting slot
            events.publishPackageChanged(3) // must close the session instead of losing state
            assertTrue(connectionClosed.await(1, TimeUnit.SECONDS))
            assertFalse(writer.sendEvent(packageChangedEvent(4)))

            output.allowWrites.countDown()
            assertTrue(output.writeAttemptFinished.await(1, TimeUnit.SECONDS))
            assertEquals(1, output.writeAttempts.get())
            assertTrue(output.frames.isEmpty())
            assertEquals(1, closeCalls.get())
        } finally {
            output.allowWrites.countDown()
            writer.close()
        }
    }

    private fun StoreEventBus.publishPackageChanged(seq: Long) {
        publish(StoreDispatcher.STORE_METADATA_CAPABILITY) { event ->
            event.setStorePackageChanged(
                PackageChanged.newBuilder()
                    .setPackage("com.example.app")
                    .setKind(PackageChangeKind.PACKAGE_CHANGE_KIND_CHANGED)
                    .setVersionCode(seq)
            )
        }
    }

    private fun packageChangedEvent(seq: Long): Event =
        Event.newBuilder()
            .setSeq(seq)
            .setStorePackageChanged(
                PackageChanged.newBuilder()
                    .setPackage("com.example.app")
                    .setKind(PackageChangeKind.PACKAGE_CHANGE_KIND_CHANGED)
                    .setVersionCode(seq)
            )
            .build()

    private class BlockingOutputStream(expectedWrites: Int) : OutputStream() {
        val writeStarted = CountDownLatch(1)
        val allowWrites = CountDownLatch(1)
        val expectedWrites = CountDownLatch(expectedWrites)
        val writeAttemptFinished = CountDownLatch(1)
        val writeAttempts = AtomicInteger()
        val frames = CopyOnWriteArrayList<ByteArray>()

        override fun write(bytes: ByteArray, offset: Int, length: Int) {
            writeAttempts.incrementAndGet()
            writeStarted.countDown()
            try {
                if (!allowWrites.await(2, TimeUnit.SECONDS)) {
                    throw IOException("timed out waiting to release the test output stream")
                }
                frames += bytes.copyOfRange(offset, offset + length)
                expectedWrites.countDown()
            } finally {
                writeAttemptFinished.countDown()
            }
        }

        override fun write(value: Int) {
            write(byteArrayOf(value.toByte()), 0, 1)
        }
    }
}
