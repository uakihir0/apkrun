package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestProtocolFailure

/** Enforces the per-connection increasing Envelope.id rule after the handshake. */
internal class EnvelopeIdSequence(initialId: Long = 0L) {
    var lastId: Long = initialId
        private set

    fun observe(id: Long) {
        if (id <= lastId) {
            throw GuestProtocolFailure.MalformedFrame("a host envelope id did not increase")
        }
        lastId = id
    }
}
