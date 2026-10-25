package io.apkrun.guest.daemon

import android.net.LocalSocket
import android.os.Build
import android.os.ParcelFileDescriptor
import io.apkrun.guest.BuildConfig
import io.apkrun.guest.daemon.files.ExportBulkSender
import io.apkrun.guest.daemon.files.ExportFileStreamer
import io.apkrun.guest.daemon.files.MacFilesBulkHostClient
import io.apkrun.guest.daemon.files.MacFilesProviderServices
import io.apkrun.guest.protocol.AgentHandshake
import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.GuestProtocolFailure
import io.apkrun.guest.protocol.ProtocolVersion
import io.apkrun.guest.protocol.v1.AgentInfo
import io.apkrun.guest.protocol.v1.AgentKind
import io.apkrun.guest.protocol.v1.AndroidInfo
import io.apkrun.guest.protocol.v1.BulkAck
import io.apkrun.guest.protocol.v1.BulkAckStatus
import io.apkrun.guest.protocol.v1.BulkBegin
import io.apkrun.guest.protocol.v1.BulkEnd
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.BulkKind
import io.apkrun.guest.protocol.v1.ChannelKind
import io.apkrun.guest.protocol.v1.Envelope
import io.apkrun.guest.protocol.v1.Hello
import io.apkrun.guest.protocol.v1.InputAck
import io.apkrun.guest.protocol.v1.ProtocolVersion as WireProtocolVersion
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import java.io.EOFException
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import kotlinx.coroutines.launch

/** How long the agent waits for HelloAck after its Hello (guest-protocol.md §5.1). */
private const val HANDSHAKE_TIMEOUT_MILLIS = 5_000

/**
 * One accepted connection of the daemon: the handshake (guest-protocol.md §5), then the loop of its
 * channel (guest-protocol.md §3). A protocol violation closes the connection and is logged with the
 * envelope id only (guest-protocol.md §12.2).
 */
internal class Connection(
    private val socket: LocalSocket,
    private val channel: ChannelKind,
    private val daemon: Daemon,
) : ExportBulkSender {
    private val writer = FrameWriter(socket.outputStream)
    private val reader = FrameReader(socket.inputStream)
    private val hostRequests = ConcurrentHashMap<Long, CompletableFuture<Response>>()
    private val pendingBulkAcks = ConcurrentHashMap<Long, CompletableFuture<BulkAck>>()
    private val outgoingBulkSlots = Semaphore(MAXIMUM_OUTGOING_TRANSFERS)
    private val abandonedHostRequests = ConcurrentHashMap.newKeySet<Long>()
    private val hostRequestSlots = Semaphore(MAXIMUM_HOST_REQUESTS)
    private val hostRequestLifecycleLock = Any()
    private var hostConnectionClosed = false
    private val hostClient =
        if (
            channel == ChannelKind.CHANNEL_KIND_GUEST_BULK &&
                daemon.mode == io.apkrun.guest.protocol.v1.AgentMode.AGENT_MODE_PRIVILEGED_APP
        ) {
            MacFilesBulkHostClient(this)
        } else {
            null
        }

    /** Runs the connection until it closes. It never throws. */
    fun run() {
        try {
            serve()
        } catch (failure: GuestProtocolFailure) {
            AgentLog.warning("closed the ${channel.name} connection: ${failure.message}")
        } catch (end: EOFException) {
            AgentLog.info("the ${channel.name} connection closed")
        } catch (error: IOException) {
            AgentLog.info("the ${channel.name} connection ended: ${error.javaClass.simpleName}")
        } finally {
            hostClient?.let(MacFilesProviderServices::clearHostClient)
            synchronized(hostRequestLifecycleLock) {
                hostConnectionClosed = true
                failPendingHostRequests(IOException("the bulk connection closed"))
            }
            pendingBulkAcks.values.forEach {
                it.completeExceptionally(IOException("the bulk connection closed"))
            }
            pendingBulkAcks.clear()
            socket.close()
        }
    }

    private fun serve() {
        if (channel == ChannelKind.CHANNEL_KIND_GUEST_CONTROL) {
            serveControl()
        } else {
            serveSecondary()
        }
    }

    /**
     * The control connection. It holds the handshake from its admission until it ends, so that a
     * second handshake is refused while this one runs, and a taken-over session is closed
     * (guest-protocol.md §5.4). The end of this connection releases only its own claim on the
     * session.
     */
    private fun serveControl() {
        daemon.sessions.admitControl(socket)?.let { reason ->
            AgentLog.warning("refused a control connection: ${reason.name}")
            return
        }
        var exportControlConnected = false
        try {
            val negotiated = handshake()
            if (!daemon.sessions.openControl(socket, negotiated.token)) {
                return
            }
            daemon.events.attach(writer, negotiated.enabled)
            daemon.controlConnected(socket)
            exportControlConnected = true
            try {
                controlLoop(negotiated.enabled, negotiated.lastHostEnvelopeId)
            } finally {
                daemon.events.detach(writer)
            }
        } finally {
            if (daemon.sessions.endControl(socket)) {
                if (exportControlConnected) daemon.controlDisconnected(socket)
                daemon.input.resetState()
            }
        }
    }

    private fun serveSecondary() {
        val negotiated = handshake()
        daemon.sessions.admitSecondary(negotiated.token)?.let { reason ->
            AgentLog.warning("refused a ${channel.name} connection: ${reason.name}")
            return
        }
        daemon.sessions.track(socket)
        try {
            if (
                channel == ChannelKind.CHANNEL_KIND_GUEST_BULK &&
                    GuestCapability.FILES in negotiated.enabled &&
                    GuestCapability.BULK in negotiated.enabled
            ) {
                daemon.exports?.attachBulkSender(this)
            }
            if (
                channel == ChannelKind.CHANNEL_KIND_GUEST_BULK &&
                    GuestCapability.FILES_SHARED in negotiated.enabled &&
                    hostClient != null
            ) {
                MacFilesProviderServices.installHostClient(hostClient)
            }
            secondaryLoop(negotiated.enabled, negotiated.lastHostEnvelopeId)
        } finally {
            if (
                channel == ChannelKind.CHANNEL_KIND_GUEST_BULK &&
                    GuestCapability.FILES in negotiated.enabled &&
                    GuestCapability.BULK in negotiated.enabled
            ) {
                daemon.exports?.detachBulkSender(this)
            }
            daemon.sessions.untrack(socket)
            if (channel == ChannelKind.CHANNEL_KIND_GUEST_BULK) {
                daemon.files?.abortIncompleteTransfers(this)
            }
            if (channel == ChannelKind.CHANNEL_KIND_GUEST_INPUT) {
                // A closed input stream releases the gestures it left open (input.md §7.3).
                daemon.input.streamClosed(this)
            }
        }
    }

    /**
     * What the handshake established: the capabilities that both sides use, and the session token.
     */
    private class Negotiated(
        val enabled: Set<GuestCapability>,
        val token: ByteArray,
        val lastHostEnvelopeId: Long,
    )

    /**
     * Sends the Hello, and reads the HelloAck that the host answers with (guest-protocol.md §5.1).
     */
    private fun handshake(): Negotiated {
        writer.send { it.setHello(hello()) }
        socket.soTimeout = HANDSHAKE_TIMEOUT_MILLIS
        val ack = reader.next()
        if (ack.bodyCase != Envelope.BodyCase.HELLO_ACK) {
            socket.soTimeout = 0
            throw GuestProtocolFailure.MalformedFrame(
                "the first frame from the host is not a valid HelloAck"
            )
        }
        val hostEnvelopeSequence = EnvelopeIdSequence()
        hostEnvelopeSequence.observe(ack.id)
        socket.soTimeout = 0
        val accepted =
            AgentHandshake.evaluate(
                ack.helloAck,
                ProtocolVersion.HOST,
                daemon.supportedCapabilities(),
            )
        val enabled =
            GuestCapability.entries.filter { it.wireName in accepted.enabledCapabilities }.toSet()
        return Negotiated(enabled, accepted.sessionToken, hostEnvelopeSequence.lastId)
    }

    /**
     * Requests of the control connection, answered in their own coroutines (guest-protocol.md §6).
     */
    private fun controlLoop(enabled: Set<GuestCapability>, initialHostEnvelopeId: Long) {
        val hostEnvelopeSequence = EnvelopeIdSequence(initialHostEnvelopeId)
        while (true) {
            val envelope = reader.next()
            hostEnvelopeSequence.observe(envelope.id)
            daemon.sessions.recordControlActivity()
            when (envelope.bodyCase) {
                Envelope.BodyCase.REQUEST -> {
                    val id = envelope.id
                    val request = envelope.request
                    daemon.scope.launch {
                        try {
                            val response = daemon.dispatcher.dispatch(id, request, enabled)
                            writer.send(replyTo = id) { it.setResponse(response) }
                            daemon.responseSent(id)
                        } catch (error: IOException) {
                            daemon.responseFailed(id)
                            // The host closed the connection while the request ran, so nothing
                            // reads the answer.
                            // The agent keeps running (guest-protocol.md §4.1).
                            AgentLog.info(
                                "the answer to request $id was not sent: ${error.javaClass.simpleName}"
                            )
                        }
                    }
                }
                Envelope.BodyCase.CANCEL -> daemon.dispatcher.cancel(envelope.cancel.targetId)
                else ->
                    throw GuestProtocolFailure.MalformedFrame(
                        "the body is not allowed on the control channel"
                    )
            }
        }
    }

    /**
     * Input and bulk connections. The input stream has no request and response pairs
     * (guest-protocol.md §9).
     */
    private fun secondaryLoop(
        enabled: Set<GuestCapability>,
        initialHostEnvelopeId: Long,
    ) {
        val hostEnvelopeSequence = EnvelopeIdSequence(initialHostEnvelopeId)
        while (true) {
            val envelope = reader.next()
            hostEnvelopeSequence.observe(envelope.id)
            when (channel) {
                ChannelKind.CHANNEL_KIND_GUEST_INPUT ->
                    if (envelope.bodyCase == Envelope.BodyCase.INPUT_BATCH) {
                        // A batch that the framework cannot apply is logged and dropped, and the
                        // stream stays open (guest-protocol.md §9). Only a frame that breaks the
                        // protocol closes it. The ack is sent later, from the injector thread.
                        try {
                            daemon.input.submit(
                                this,
                                envelope.inputBatch,
                                ackTraceEnabled = GuestCapability.INPUT_ACK_TRACE in enabled,
                            ) { ack ->
                                sendInputAck(ack)
                            }
                        } catch (error: Exception) {
                            AgentLog.error("an input batch could not be applied", error)
                        }
                    } else {
                        throw GuestProtocolFailure.MalformedFrame(
                            "the body is not allowed on the input channel"
                        )
                    }
                ChannelKind.CHANNEL_KIND_GUEST_BULK -> {
                    when (envelope.bodyCase) {
                        Envelope.BodyCase.BULK -> {
                            val frame = envelope.bulk
                            if (frame.kindCase == BulkFrame.KindCase.ACK) {
                                if (
                                    GuestCapability.FILES !in enabled ||
                                        GuestCapability.BULK !in enabled
                                ) {
                                    throw GuestProtocolFailure.MalformedFrame(
                                        "a bulk acknowledgement arrived without files.v1"
                                    )
                                }
                                receiveBulkAck(frame)
                                continue
                            }
                            if (
                                GuestCapability.FILES !in enabled ||
                                    GuestCapability.BULK !in enabled ||
                                    daemon.files == null
                            ) {
                                throw GuestProtocolFailure.MalformedFrame(
                                    "a bulk transfer arrived without an enabled files capability"
                                )
                            }
                            val status = daemon.files.receive(frame, this)
                            if (status != null) sendBulkAck(frame.transferId, status)
                        }
                        Envelope.BodyCase.RESPONSE -> {
                            if (GuestCapability.FILES_SHARED !in enabled) {
                                throw GuestProtocolFailure.MalformedFrame(
                                    "a reverse file response arrived without files.shared.v1"
                                )
                            }
                            receiveHostResponse(envelope)
                        }
                        else ->
                            throw GuestProtocolFailure.MalformedFrame(
                                "the body is not allowed on the bulk channel"
                            )
                    }
                }
                else ->
                    throw GuestProtocolFailure.MalformedFrame(
                        "the channel ${channel.name} is not served here"
                    )
            }
        }
    }

    /**
     * Sends the ack of an input batch. It runs on the injector thread, and [FrameWriter.send] is
     * safe to call from there. A closed connection loses the ack, and nothing else.
     */
    private fun sendInputAck(ack: InputAck) {
        try {
            writer.send { it.setInputAck(ack) }
        } catch (error: IOException) {
            AgentLog.info("an input ack was not sent: ${error.javaClass.simpleName}")
        }
    }

    /** Sends the final status of an incoming file transfer on the same bulk stream. */
    private fun sendBulkAck(transferId: Long, status: BulkAckStatus) {
        try {
            writer.send {
                it.setBulk(
                    BulkFrame.newBuilder()
                        .setTransferId(transferId)
                        .setAck(BulkAck.newBuilder().setStatus(status))
                )
            }
        } catch (error: IOException) {
            AgentLog.info(
                "a bulk transfer acknowledgement was not sent: ${error.javaClass.simpleName}"
            )
        }
    }

    /**
     * Streams an accepted Android content URI to the host without buffering the whole file. BulkEnd
     * carries the SHA-256 of the exact bytes sent, as required for file exports.
     */
    override fun send(
        transferId: Long,
        descriptor: ParcelFileDescriptor,
        name: String,
        mimeType: String,
        size: Long,
    ) {
        if (
            channel != ChannelKind.CHANNEL_KIND_GUEST_BULK ||
                transferId <= 0L ||
                transferId % 2L != 1L ||
                size !in 0L..MAXIMUM_EXPORT_BYTES
        ) {
            throw IOException("the export transfer is not valid")
        }
        if (!outgoingBulkSlots.tryAcquire()) {
            throw IOException("too many bulk transfers are in flight")
        }
        val completion = CompletableFuture<BulkAck>()
        if (pendingBulkAcks.putIfAbsent(transferId, completion) != null) {
            outgoingBulkSlots.release()
            throw IOException("the export transfer ID is already in use")
        }

        var began = false
        var ended = false
        try {
            writer.send {
                it.setBulk(
                    BulkFrame.newBuilder()
                        .setTransferId(transferId)
                        .setBegin(
                            BulkBegin.newBuilder()
                                .setKind(BulkKind.BULK_KIND_FILE)
                                .setName(name)
                                .setMimeType(mimeType)
                                .setSize(size)
                        )
                )
            }
            began = true

            ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                ExportFileStreamer.stream(
                    input,
                    size,
                    sendChunk = { chunk ->
                        writer.send {
                            it.setBulk(
                                BulkFrame.newBuilder().setTransferId(transferId).setChunk(chunk)
                            )
                        }
                    },
                    sendEnd = { sha256 ->
                        writer.send {
                            it.setBulk(
                                BulkFrame.newBuilder()
                                    .setTransferId(transferId)
                                    .setEnd(BulkEnd.newBuilder().setSha256(sha256))
                            )
                        }
                        ended = true
                    },
                )
            }

            val ack =
                try {
                    completion.get(BULK_ACK_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
                } catch (timeout: TimeoutException) {
                    throw IOException("the host did not acknowledge the export transfer", timeout)
                } catch (error: ExecutionException) {
                    throw IOException(
                        "the bulk connection closed before the export was acknowledged",
                        error,
                    )
                } catch (interrupted: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw IOException("the export transfer was interrupted", interrupted)
                }
            if (ack.status != BulkAckStatus.BULK_ACK_STATUS_OK) {
                throw IOException("the host rejected the export transfer")
            }
        } catch (error: Exception) {
            if (began && !ended) {
                runCatching {
                    writer.send {
                        it.setBulk(
                            BulkFrame.newBuilder()
                                .setTransferId(transferId)
                                .setAbort(
                                    io.apkrun.guest.protocol.v1.BulkAbort.newBuilder()
                                        .setReason("transferFailed")
                                )
                        )
                    }
                }
            }
            if (error is IOException) throw error
            throw IOException("the export transfer failed", error)
        } finally {
            pendingBulkAcks.remove(transferId, completion)
            outgoingBulkSlots.release()
        }
    }

    private fun receiveBulkAck(frame: BulkFrame) {
        val completion =
            pendingBulkAcks[frame.transferId]
                ?: throw GuestProtocolFailure.MalformedFrame(
                    "the host acknowledged an unknown bulk transfer"
                )
        if (!completion.complete(frame.ack)) {
            throw GuestProtocolFailure.MalformedFrame(
                "the host acknowledged a bulk transfer more than once"
            )
        }
    }

    /**
     * Sends one agent-to-host shared-folder request and waits for its matching response.
     *
     * This is called on DocumentsProvider callback threads, never on the bulk reader thread.
     */
    internal fun requestHost(request: Request): Response {
        if (channel != ChannelKind.CHANNEL_KIND_GUEST_BULK || hostClient == null) {
            throw IOException("shared-folder access is unavailable")
        }
        if (!hostRequestSlots.tryAcquire()) {
            throw IOException("too many shared-folder requests are in flight")
        }

        val completion = CompletableFuture<Response>()
        var requestId: Long? = null
        try {
            synchronized(hostRequestLifecycleLock) {
                if (hostConnectionClosed) throw IOException("the bulk connection is closed")
                requestId =
                    writer.sendWithId(
                        onAllocated = { id ->
                            if (hostRequests.putIfAbsent(id, completion) != null) {
                                throw IOException("duplicate shared-folder request id")
                            }
                        }
                    ) { envelope ->
                        envelope.setRequest(request)
                    }
            }
            return completion.get(HOST_REQUEST_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
        } catch (timeout: TimeoutException) {
            requestId?.let { id ->
                if (hostRequests.remove(id, completion)) abandonedHostRequests.add(id)
            }
            // The host has no reverse-request cancellation operation. Closing the bulk stream
            // releases connection-scoped host handles, including a HostOpenFile result that
            // finishes after this timeout.
            try {
                socket.close()
            } catch (_: IOException) {
                // The connection teardown in run() still owns pending-call cleanup.
            }
            throw SocketTimeoutException("the host did not answer the shared-folder request")
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
            requestId?.let { id ->
                if (hostRequests.remove(id, completion)) abandonedHostRequests.add(id)
            }
            // The host has no reverse-request cancellation operation. If an open completes later,
            // disconnecting releases its connection-scoped descriptor instead of leaking it.
            try {
                socket.close()
            } catch (_: IOException) {
                // The connection teardown in run() still owns pending-call cleanup.
            }
            throw IOException("the shared-folder request was interrupted", interrupted)
        } catch (wrapped: ExecutionException) {
            throw (wrapped.cause as? IOException)
                ?: IOException("the shared-folder request failed", wrapped.cause)
        } catch (error: IOException) {
            requestId?.let { id ->
                if (hostRequests.remove(id, completion)) abandonedHostRequests.add(id)
            }
            throw error
        } finally {
            hostRequestSlots.release()
        }
    }

    /** Delivers a response to one reverse request; timed-out responses are discarded. */
    private fun receiveHostResponse(envelope: Envelope) {
        if (envelope.replyTo == 0L || envelope.id == 0L) {
            throw GuestProtocolFailure.MalformedFrame("a reverse file response has an invalid id")
        }
        val completion = hostRequests.remove(envelope.replyTo)
        if (completion != null) {
            completion.complete(envelope.response)
        } else if (!abandonedHostRequests.remove(envelope.replyTo)) {
            throw GuestProtocolFailure.MalformedFrame(
                "the host answered a request that was not in flight"
            )
        }
    }

    private fun failPendingHostRequests(error: IOException) {
        val pending = hostRequests.values
        hostRequests.clear()
        pending.forEach { it.completeExceptionally(error) }
        abandonedHostRequests.clear()
    }

    private fun hello(): Hello =
        Hello.newBuilder()
            .setProtocolVersion(
                WireProtocolVersion.newBuilder()
                    .setMajor(ProtocolVersion.HOST.major.toInt())
                    .setMinor(ProtocolVersion.HOST.minor.toInt())
            )
            .setAgent(
                AgentInfo.newBuilder()
                    .setKind(AgentKind.AGENT_KIND_GUEST_AGENT)
                    .setVersionName(BuildConfig.VERSION_NAME)
                    .setVersionCode(BuildConfig.VERSION_CODE.toLong())
                    .setBuildId(BuildConfig.VERSION_NAME)
            )
            .setRuntimeImageVersion(HiddenApi.systemProperty("ro.boot.apkrun.image").orEmpty())
            .setAndroid(
                AndroidInfo.newBuilder()
                    .setSdkInt(Build.VERSION.SDK_INT)
                    .setRelease(Build.VERSION.RELEASE)
                    .setBuildFingerprint(Build.FINGERPRINT)
                    .setBuildType(Build.TYPE)
            )
            .addAllCapabilities(daemon.supportedCapabilities().map { it.wireName })
            .setChannel(channel)
            .setMode(daemon.mode)
            .build()

    companion object {
        private const val MAXIMUM_HOST_REQUESTS = 16
        private const val MAXIMUM_OUTGOING_TRANSFERS = 4
        private const val MAXIMUM_EXPORT_BYTES = 2L * 1024L * 1024L * 1024L
        private const val HOST_REQUEST_TIMEOUT_MILLIS = 30_000L
        private const val BULK_ACK_TIMEOUT_MILLIS = 300_000L

        /** The capabilities that this build implements (guest-protocol.md §5.3). */
        val IMPLEMENTED: Set<GuestCapability> =
            setOf(
                GuestCapability.CORE,
                GuestCapability.DISPLAY,
                GuestCapability.LAUNCH,
                GuestCapability.INPUT,
                GuestCapability.INPUT_ACK_TRACE,
                GuestCapability.PACKAGES,
                GuestCapability.FILES,
                GuestCapability.BULK,
                GuestCapability.HEALTH,
                GuestCapability.SYSTEM,
            )
    }
}
