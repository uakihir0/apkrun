package io.apkrun.guest.files

import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.v1.GuestError
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import io.apkrun.guest.runtime.AgentLog
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Sends agent→host file requests on the bulk connection and waits for the answers
 * (desktop-integration.md §6.4, guest-protocol.md §7.4–7.5). The shared-folder Host* operations
 * (60–69) are the only requests the agent originates; they travel as `request` envelopes and the
 * host replies with a `response` envelope whose replyTo names the request's id. One request runs at
 * a time per caller: the latch of a timed-out request stays registered until a reply with the same
 * id arrives, and the id advances so a late reply can never confuse the next call.
 */
internal class HostFileClient {

    private class Pending(val latch: CountDownLatch = CountDownLatch(1)) {
        @Volatile var response: Response? = null
        @Volatile var disconnected = false
    }

    private val lock = Any()
    private val writers = ArrayList<FrameWriter>()
    private val pending = HashMap<Long, Pending>()

    /** Registers a bulk connection writer; requests can run while at least one is attached. */
    fun attach(writer: FrameWriter) {
        synchronized(lock) { writers.add(writer) }
    }

    /** Drops a writer and fails the requests still waiting on it. */
    fun detach(writer: FrameWriter) {
        synchronized(lock) {
            writers.remove(writer)
            if (writers.isEmpty()) {
                for (entry in pending.values) {
                    entry.disconnected = true
                    entry.latch.countDown()
                }
            }
        }
    }

    /** Routes a `response` envelope from the bulk connection to the waiting caller. */
    fun accept(response: Response, replyTo: Long) {
        val entry = synchronized(lock) { pending.remove(replyTo) } ?: return
        entry.response = response
        entry.latch.countDown()
    }

    /**
     * Runs one request and returns the response, or `null` when no bulk channel is attached, the
     * host dropped it, or the reply did not arrive within [timeoutMs]. A response carrying an error
     * is returned as is — the caller reads it.
     */
    fun call(build: (Request.Builder) -> Unit, timeoutMs: Long = DEFAULT_TIMEOUT_MS): Response? {
        val target: FrameWriter
        val entry: Pending
        var requestId = -1L
        synchronized(lock) {
            target = writers.firstOrNull() ?: return null
            entry = Pending()
        }
        try {
            target.sendRequest(
                onId = { id ->
                    synchronized(lock) { pending[id] = entry }
                    requestId = id
                }
            ) { envelope ->
                val request = Request.newBuilder()
                build(request)
                envelope.request = request.build()
            }
        } catch (error: Exception) {
            synchronized(lock) { pending.remove(requestId) }
            AgentLog.info("a host file request could not be sent: ${error.javaClass.simpleName}")
            return null
        }
        return try {
            if (!entry.latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                synchronized(lock) { pending.remove(requestId) }
                null
            } else if (entry.disconnected) {
                null
            } else {
                entry.response
            }
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            synchronized(lock) { pending.remove(requestId) }
            null
        }
    }

    /** The error of a failed response, or `null` when the response carries a result. */
    fun errorOf(response: Response): GuestError? {
        if (response.hasError()) {
            return response.error
        }
        return null
    }

    /** A fallback error when the channel itself failed, for call sites that need one. */
    fun channelError(): GuestError =
        GuestError.newBuilder()
            .setCode(GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE)
            .setMessage("the host channel is not connected")
            .build()

    companion object {
        const val DEFAULT_TIMEOUT_MS = 30_000L
    }
}
