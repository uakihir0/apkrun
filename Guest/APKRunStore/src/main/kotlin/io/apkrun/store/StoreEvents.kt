package io.apkrun.store

import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.InstallFinished
import io.apkrun.guest.protocol.v1.InstallProgress
import io.apkrun.guest.runtime.AgentLog
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

/**
 * The event stream of the store control connection (guest-protocol.md §8.1, §11.2). One control
 * connection at a time carries events; [attach] on a new connection replaces the previous sink.
 * `seq` is per connection and starts at 1.
 */
class StoreEvents {
    private val lock = Any()
    private var writer: FrameWriter? = null
    private var seq = AtomicLong(0)

    fun attach(writer: FrameWriter) {
        synchronized(lock) {
            this.writer = writer
            seq.set(0)
        }
    }

    fun detach(writer: FrameWriter) {
        synchronized(lock) {
            if (this.writer === writer) {
                this.writer = null
            }
        }
    }

    fun installProgress(progress: InstallProgress) = send { it.setInstallProgress(progress) }

    fun installFinished(finished: InstallFinished) = send { it.setInstallFinished(finished) }

    private fun send(build: (Event.Builder) -> Unit) {
        val sink =
            synchronized(lock) {
                writer?.let { it to seq.incrementAndGet() }
            } ?: return
        val (frameWriter, sequence) = sink
        try {
            val event = Event.newBuilder().setSeq(sequence)
            build(event)
            frameWriter.send { it.setEvent(event) }
        } catch (error: IOException) {
            AgentLog.info("a store event could not be sent: ${error.javaClass.simpleName}")
        }
    }
}
