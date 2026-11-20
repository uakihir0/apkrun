package io.apkrun.store

import android.net.LocalSocket
import android.os.Build
import io.apkrun.guest.protocol.AgentHandshake
import io.apkrun.guest.protocol.FrameReader
import io.apkrun.guest.protocol.FrameWriter
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
 * One accepted connection of the Store Agent: the handshake (guest-protocol.md §5), then the loop
 * of its channel (guest-protocol.md §3, §11). The control connection carries requests and events;
 * the artifact connection carries the `BulkFrame` stream of installs and inspections.
 */
class StoreConnection(
    private val socket: LocalSocket,
    private val channel: ChannelKind,
    private val daemon: StoreDaemon,
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
        if (channel == ChannelKind.CHANNEL_KIND_STORE_CONTROL) {
            serveControl()
        } else {
            serveArtifacts()
        }
    }

    private fun serveControl() {
        daemon.sessions.admitControl(socket)?.let { reason ->
            AgentLog.warning("refused a store control connection: ${reason.name}")
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
                // A control connection that closes abandons every uncommitted install
                // (guest-protocol.md §11.3).
                daemon.install.controlClosed()
            }
        }
    }

    private fun serveArtifacts() {
        val negotiated = handshake()
        daemon.sessions.admitSecondary(negotiated.token)?.let { reason ->
            AgentLog.warning("refused a ${channel.name} connection: ${reason.name}")
            return
        }
        daemon.sessions.track(socket)
        try {
            while (true) {
                val envelope = reader.next()
                if (envelope.bodyCase != Envelope.BodyCase.BULK) {
                    throw GuestProtocolFailure.MalformedFrame(
                        "the body is not allowed on the artifact channel"
                    )
                }
                daemon.install.receive(envelope.bulk) { reply -> writer.send { it.setBulk(reply) } }
            }
        } finally {
            daemon.sessions.untrack(socket)
        }
    }

    private class Negotiated(val enabled: Set<GuestCapability>, val token: ByteArray)

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
                            AgentLog.info(
                                "the answer to request $id was not sent: ${error.javaClass.simpleName}"
                            )
                        }
                    }
                }
                Envelope.BodyCase.CANCEL -> daemon.dispatcher.cancel(envelope.cancel.targetId)
                else ->
                    throw GuestProtocolFailure.MalformedFrame(
                        "the body is not allowed on the store control channel"
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
                    .setKind(AgentKind.AGENT_KIND_STORE_AGENT)
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
            .setMode(AgentMode.AGENT_MODE_PRIVILEGED_APP)
            .putCapabilityDetails(
                GuestCapability.STORE_OWNERSHIP.wireName,
                "enforcement=" + if (daemon.ownershipEnforcement()) "on" else "off",
            )
            .build()

    companion object {
        /** The capabilities that this build implements (guest-protocol.md §5.3, §11). */
        val IMPLEMENTED: Set<GuestCapability> =
            setOf(
                GuestCapability.CORE,
                GuestCapability.STORE_INSTALL,
                GuestCapability.STORE_METADATA,
                GuestCapability.STORE_OWNERSHIP,
                GuestCapability.STORE_CONSTRAINTS,
            )
    }
}
