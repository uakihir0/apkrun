package io.apkrun.guest.daemon

import android.net.LocalSocket
import android.os.Build
import io.apkrun.guest.BuildConfig
import io.apkrun.guest.protocol.AgentHandshake
import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.GuestProtocolFailure
import io.apkrun.guest.protocol.ProtocolVersion
import io.apkrun.guest.protocol.v1.AgentInfo
import io.apkrun.guest.protocol.v1.AgentKind
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.protocol.v1.AndroidInfo
import io.apkrun.guest.protocol.v1.ChannelKind
import io.apkrun.guest.protocol.v1.Envelope
import io.apkrun.guest.protocol.v1.Hello
import io.apkrun.guest.protocol.v1.ProtocolVersion as WireProtocolVersion
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import java.io.EOFException
import java.io.IOException
import kotlinx.coroutines.launch

/** How long the agent waits for HelloAck after its Hello (guest-protocol.md §5.1). */
private const val HANDSHAKE_TIMEOUT_MILLIS = 5_000

/**
 * One accepted connection of the daemon: the handshake (guest-protocol.md §5), then the loop of its
 * channel (guest-protocol.md §3). A protocol violation closes the connection and is logged with the
 * envelope id only (guest-protocol.md §12.2).
 */
class Connection(
    private val socket: LocalSocket,
    private val channel: ChannelKind,
    private val daemon: Daemon,
) {
    private val writer = FrameWriter(socket.outputStream)
    private val reader = FrameReader(socket.inputStream)

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
        try {
            val negotiated = handshake()
            if (!daemon.sessions.openControl(socket, negotiated.token)) {
                return
            }
            daemon.events.attach(writer)
            try {
                controlLoop(negotiated.enabled)
            } finally {
                daemon.events.detach(writer)
            }
        } finally {
            if (daemon.sessions.endControl(socket)) {
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
            secondaryLoop()
        } finally {
            daemon.sessions.untrack(socket)
        }
    }

    /**
     * What the handshake established: the capabilities that both sides use, and the session token.
     */
    private class Negotiated(val enabled: Set<GuestCapability>, val token: ByteArray)

    /**
     * Sends the Hello, and reads the HelloAck that the host answers with (guest-protocol.md §5.1).
     */
    private fun handshake(): Negotiated {
        writer.send { it.setHello(hello()) }
        socket.soTimeout = HANDSHAKE_TIMEOUT_MILLIS
        val ack = reader.next()
        socket.soTimeout = 0
        if (ack.bodyCase != Envelope.BodyCase.HELLO_ACK) {
            throw GuestProtocolFailure.MalformedFrame(
                "the first frame from the host is not HelloAck"
            )
        }
        val accepted = AgentHandshake.evaluate(ack.helloAck, ProtocolVersion.HOST, IMPLEMENTED)
        val enabled =
            GuestCapability.entries.filter { it.wireName in accepted.enabledCapabilities }.toSet()
        return Negotiated(enabled, accepted.sessionToken)
    }

    /**
     * Requests of the control connection, answered in their own coroutines (guest-protocol.md §6).
     */
    private fun controlLoop(enabled: Set<GuestCapability>) {
        var lastRequestId = 0L
        while (true) {
            val envelope = reader.next()
            daemon.sessions.recordControlActivity()
            when (envelope.bodyCase) {
                Envelope.BodyCase.REQUEST -> {
                    if (envelope.id <= lastRequestId) {
                        throw GuestProtocolFailure.MalformedFrame("a request id did not increase")
                    }
                    lastRequestId = envelope.id
                    val id = envelope.id
                    val request = envelope.request
                    daemon.scope.launch {
                        try {
                            val response = daemon.dispatcher.dispatch(id, request, enabled)
                            writer.send(replyTo = id) { it.setResponse(response) }
                        } catch (error: IOException) {
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
    private fun secondaryLoop() {
        while (true) {
            val envelope = reader.next()
            when (channel) {
                ChannelKind.CHANNEL_KIND_GUEST_INPUT ->
                    if (envelope.bodyCase == Envelope.BodyCase.INPUT_BATCH) {
                        // A batch that the framework cannot apply is logged and dropped, and the
                        // stream stays
                        // open (guest-protocol.md §9). Only a frame that breaks the protocol closes
                        // it.
                        val ack =
                            try {
                                daemon.input.submit(envelope.inputBatch)
                            } catch (error: Exception) {
                                AgentLog.error("an input batch could not be applied", error)
                                null
                            }
                        if (ack != null) {
                            writer.send { it.setInputAck(ack) }
                        }
                    } else {
                        throw GuestProtocolFailure.MalformedFrame(
                            "the body is not allowed on the input channel"
                        )
                    }
                // The bulk channel carries transfers, which arrive with #070 and #080. Until then
                // its frames are read and dropped.
                ChannelKind.CHANNEL_KIND_GUEST_BULK -> Unit
                else ->
                    throw GuestProtocolFailure.MalformedFrame(
                        "the channel ${channel.name} is not served here"
                    )
            }
        }
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
            .addAllCapabilities(IMPLEMENTED.map { it.wireName })
            .setChannel(channel)
            .setMode(AgentMode.AGENT_MODE_DEVELOPMENT_SHELL)
            .build()

    companion object {
        /** The capabilities that this build implements (guest-protocol.md §5.3). */
        val IMPLEMENTED: Set<GuestCapability> =
            setOf(
                GuestCapability.CORE,
                GuestCapability.DISPLAY,
                GuestCapability.LAUNCH,
                GuestCapability.INPUT,
            )
    }
}
