package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.Event

/**
 * The ordered events of the attached control connection (guest-components.md §6.1,
 * guest-protocol.md §6). The sequence number starts at 1 for each connection. With no control
 * connection attached, an event is dropped: the host reads a snapshot after every handshake and
 * does not need the events it missed (guest-protocol.md §1).
 */
class EventBus {
    private var writer: FrameWriter? = null
    private var sequence = 0L

    /** Makes [target] the connection of the events, and restarts the sequence. */
    @Synchronized
    fun attach(target: FrameWriter) {
        writer = target
        sequence = 0L
    }

    /** Stops the events of [target] when it is still the attached connection. */
    @Synchronized
    fun detach(target: FrameWriter) {
        if (writer === target) {
            writer = null
        }
    }

    /**
     * Sends one event, with the next sequence number. Events are sent in the order that they are
     * published.
     */
    @Synchronized
    fun publish(build: (Event.Builder) -> Unit) {
        val target = writer ?: return
        sequence += 1
        val event = Event.newBuilder().setSeq(sequence)
        build(event)
        target.send { it.setEvent(event) }
    }
}
