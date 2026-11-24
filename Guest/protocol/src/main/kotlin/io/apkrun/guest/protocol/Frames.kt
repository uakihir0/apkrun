package io.apkrun.guest.protocol

import io.apkrun.guest.protocol.v1.Envelope
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream

/**
 * Writes the frames of one connection (guest-protocol.md §4). Each frame is written whole, under
 * one lock, so two writers never interleave. The envelope ids are the agent's own, starting at 1
 * and strictly increasing.
 */
class FrameWriter(private val output: OutputStream) {
    private var nextId = 1L

    /** Sends one envelope. [replyTo] is the id of the request this envelope answers, or 0. */
    @Synchronized
    fun send(replyTo: Long = 0L, body: (Envelope.Builder) -> Unit) {
        val envelope = Envelope.newBuilder().setId(nextId).setReplyTo(replyTo)
        nextId += 1
        body(envelope)
        output.write(FrameCodec.encode(envelope.build()))
        output.flush()
    }

    /**
     * Sends one envelope with an explicit id. The agent-originated file requests of the files
     * integration carry the id their caller waits on, so the caller picks it before the frame
     * leaves (guest-protocol.md §12). [nextId] still moves past any id this call uses.
     */
    @Synchronized
    fun sendRequest(id: Long, body: (Envelope.Builder) -> Unit) {
        if (id >= nextId) {
            nextId = id + 1
        }
        val envelope = Envelope.newBuilder().setId(id).setReplyTo(0)
        body(envelope)
        output.write(FrameCodec.encode(envelope.build()))
        output.flush()
    }

    /**
     * Sends one envelope with the next id of the shared agent sequence and reports it to [onId]
     * before the frame leaves, so the caller can register its waiter first. Envelope ids are one
     * strictly increasing space per connection (guest-protocol.md §5), so the request id must come
     * from this sequence — an id the caller picks itself can collide with an auto-assigned one.
     */
    @Synchronized
    fun sendRequest(onId: (Long) -> Unit, body: (Envelope.Builder) -> Unit) {
        val id = nextId
        nextId += 1
        onId(id)
        val envelope = Envelope.newBuilder().setId(id).setReplyTo(0)
        body(envelope)
        output.write(FrameCodec.encode(envelope.build()))
        output.flush()
    }
}

/**
 * Reads the frames of one connection. A bad length or a body that does not decode throws a
 * [io.apkrun.guest.protocol.GuestProtocolFailure], and a closed connection throws [EOFException].
 */
class FrameReader(private val input: InputStream) {
    private val decoder = FrameDecoder()
    private val buffer = ByteArray(READ_BUFFER_BYTES)

    /** Blocks until the next complete envelope arrives. */
    fun next(): Envelope {
        while (true) {
            val body = decoder.nextBody()
            if (body != null) {
                return FrameCodec.decodeBody(body)
            }
            val count = input.read(buffer)
            if (count < 0) {
                throw EOFException("the connection closed")
            }
            decoder.append(buffer.copyOf(count))
        }
    }

    private companion object {
        const val READ_BUFFER_BYTES = 64 * 1024
    }
}
