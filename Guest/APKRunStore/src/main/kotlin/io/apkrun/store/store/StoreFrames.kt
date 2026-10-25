package io.apkrun.store.store

import io.apkrun.guest.protocol.FrameCodec
import io.apkrun.guest.protocol.FrameDecoder
import io.apkrun.guest.protocol.v1.Envelope
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Thread-safe writer for Store Agent control and artifact frames. */
class StoreFrameWriter(
    private val output: OutputStream,
    private val closeConnection: () -> Unit = { runCatching { output.close() } },
    eventQueueCapacity: Int = MAX_PENDING_EVENTS,
) : AutoCloseable {
    private var nextId = 1L
    private val eventStreamFailed = AtomicBoolean(false)
    private val eventExecutor =
        ThreadPoolExecutor(
            0,
            1,
            EVENT_THREAD_KEEP_ALIVE_SECONDS,
            TimeUnit.SECONDS,
            ArrayBlockingQueue(eventQueueCapacity.also { require(it > 0) }),
            { runnable -> Thread(runnable, "apkrun-store-events").apply { isDaemon = true } },
        )

    @Synchronized
    fun send(replyTo: Long = 0L, body: (Envelope.Builder) -> Unit) {
        val builder = Envelope.newBuilder().setId(nextId++).setReplyTo(replyTo)
        body(builder)
        output.write(FrameCodec.encode(builder.build()))
        output.flush()
    }

    /**
     * Enqueues an event so package broadcasts never wait for socket I/O. One worker preserves
     * submission order; a full queue closes the connection because the host must take a fresh
     * snapshot rather than continue after a missing event.
     */
    fun sendEvent(event: io.apkrun.guest.protocol.v1.Event): Boolean {
        if (eventStreamFailed.get()) return false
        return try {
            eventExecutor.execute {
                if (eventStreamFailed.get()) return@execute
                try {
                    send { it.setEvent(event) }
                } catch (_: Exception) {
                    failEventStream()
                }
            }
            true
        } catch (_: RejectedExecutionException) {
            failEventStream()
            false
        }
    }

    override fun close() {
        eventStreamFailed.set(true)
        eventExecutor.shutdownNow()
    }

    private fun failEventStream() {
        if (eventStreamFailed.compareAndSet(false, true)) {
            eventExecutor.shutdownNow()
            runCatching(closeConnection)
        }
    }

    private companion object {
        const val MAX_PENDING_EVENTS = 64
        const val EVENT_THREAD_KEEP_ALIVE_SECONDS = 30L
    }
}

/** Incremental reader for a framed Guest Protocol stream. */
class StoreFrameReader(private val input: InputStream) {
    private val decoder = FrameDecoder()
    private val buffer = ByteArray(READ_BUFFER_BYTES)

    fun next(): Envelope {
        while (true) {
            decoder.nextBody()?.let {
                return FrameCodec.decodeBody(it)
            }
            val count = input.read(buffer)
            if (count < 0) throw EOFException("the Store Agent connection closed")
            if (count == 0) continue
            decoder.append(buffer.copyOf(count))
        }
    }

    private companion object {
        const val READ_BUFFER_BYTES = 64 * 1024
    }
}

/** Maps Store Agent events to the negotiated control socket without doing socket I/O inline. */
class StoreEventBus : StoreEventSink {
    private var writer: StoreFrameWriter? = null
    private var enabledCapabilities: Set<String> = emptySet()
    private var sequence = 0L

    @Synchronized
    fun attach(target: StoreFrameWriter, enabled: Set<String>) {
        writer = target
        enabledCapabilities = enabled
        sequence = 0
    }

    @Synchronized
    fun detach(target: StoreFrameWriter) {
        if (writer === target) {
            writer = null
            enabledCapabilities = emptySet()
        }
    }

    @Synchronized
    override fun publish(
        capability: String,
        build: (io.apkrun.guest.protocol.v1.Event.Builder) -> Unit,
    ) {
        if (capability !in enabledCapabilities) return
        val destination = writer ?: return
        val event = io.apkrun.guest.protocol.v1.Event.newBuilder()
        build(event)
        event.setSeq(++sequence)
        destination.sendEvent(event.build())
    }
}
