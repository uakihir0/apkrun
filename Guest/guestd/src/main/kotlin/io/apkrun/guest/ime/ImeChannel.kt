package io.apkrun.guest.ime

import io.apkrun.guest.daemon.ActiveControlToken
import io.apkrun.guest.daemon.FrameReader
import io.apkrun.guest.daemon.FrameWriter
import io.apkrun.guest.protocol.AgentHandshake
import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.GuestProtocolFailure
import io.apkrun.guest.protocol.ProtocolVersion
import io.apkrun.guest.protocol.v1.AgentInfo
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.protocol.v1.AndroidInfo
import io.apkrun.guest.protocol.v1.ChannelKind
import io.apkrun.guest.protocol.v1.Envelope
import io.apkrun.guest.protocol.v1.Hello
import io.apkrun.guest.protocol.v1.ImeCommand
import io.apkrun.guest.protocol.v1.ImeState
import io.apkrun.guest.protocol.v1.ProtocolVersion as WireProtocolVersion
import java.io.InputStream
import java.io.OutputStream

/**
 * One accepted `@apkrun-guest-ime` connection (input.md §5.1). The IME is the agent: it sends the
 * Hello, reads the HelloAck, then serves `ime_command` frames and answers `ime_state` reports. The
 * stream keeps no request/response pairs (guest-protocol.md §9).
 *
 * The class stays framework-free: [onCommand] is invoked on the reader thread and is expected to
 * bounce the command onto the main thread, where the `InputConnection` lives.
 */
class ImeChannel(
    input: InputStream,
    output: OutputStream,
    /** The agent's own capabilities, only `ime.v1` (input.md §5.1). */
    private val capabilities: Set<GuestCapability> = setOf(GuestCapability.IME),
    /** Reports the Android build of the Hello, supplied by the service. */
    private val agentInfo: AgentInfo,
    private val androidInfo: AndroidInfo,
    private val runtimeImageVersion: String,
    /** Delivers a decoded command for application on the main thread. */
    private val onCommand: (ImeCommand) -> Unit,
    /** Runs once the handshake has been accepted, before the read loop. */
    private val onBound: () -> Unit = {},
) {
    private val reader = FrameReader(input)
    private val writer = FrameWriter(output)

    /** Reports whose delivery fails when the socket is already closed are dropped silently. */
    @Volatile private var open = true

    /**
     * Runs the handshake and then the read loop until the stream breaks or a frame violates the
     * protocol. Call it on the accept thread of the socket.
     */
    fun serve() {
        writer.send { it.setHello(hello()) }
        val ack = reader.next()
        if (ack.bodyCase != Envelope.BodyCase.HELLO_ACK) {
            throw GuestProtocolFailure.MalformedFrame(
                "the first frame from the host is not HelloAck"
            )
        }
        val negotiated = AgentHandshake.evaluate(ack.helloAck, ProtocolVersion.HOST, capabilities)
        // The IME channel is bound to the control session, as the daemon's secondary channels
        // are (guest-protocol.md §5.4): a token that is not the current control token is refused.
        if (!ActiveControlToken.matches(negotiated.sessionToken)) {
            throw GuestProtocolFailure.MalformedFrame(
                "the session token does not match the control session"
            )
        }
        onBound()
        while (true) {
            val envelope = reader.next()
            if (envelope.bodyCase != Envelope.BodyCase.IME_COMMAND) {
                throw GuestProtocolFailure.MalformedFrame(
                    "the body is not allowed on the IME channel"
                )
            }
            onCommand(envelope.imeCommand)
        }
    }

    /** Sends one `ime_state` report. Called from any thread; a closed socket drops the report. */
    fun publish(state: ImeState) {
        if (!open) return
        try {
            writer.send { it.setImeState(state) }
        } catch (error: Exception) {
            open = false
        }
    }

    /** Marks the channel closed so later reports short-circuit. */
    fun close() {
        open = false
    }

    private fun hello(): Hello =
        Hello.newBuilder()
            .setProtocolVersion(
                WireProtocolVersion.newBuilder()
                    .setMajor(ProtocolVersion.HOST.major.toInt())
                    .setMinor(ProtocolVersion.HOST.minor.toInt())
            )
            .setAgent(agentInfo)
            .setRuntimeImageVersion(runtimeImageVersion)
            .setAndroid(androidInfo)
            .addAllCapabilities(capabilities.map { it.wireName })
            .setChannel(ChannelKind.CHANNEL_KIND_DEVELOPMENT_IME)
            // The IME accepts shell peers in development; a production image does not ship it
            // (input.md §5.1).
            .setMode(AgentMode.AGENT_MODE_DEVELOPMENT_SHELL)
            .build()
}
