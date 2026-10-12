package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.InputAck
import io.apkrun.guest.protocol.v1.InputBatch
import io.apkrun.guest.protocol.v1.InputCounters
import io.apkrun.guest.protocol.v1.InputEvent
import io.apkrun.guest.protocol.v1.KeyAction
import io.apkrun.guest.protocol.v1.MouseAction
import io.apkrun.guest.protocol.v1.TouchPhase
import io.apkrun.guest.runtime.AgentLog

/** The size of a display in pixels, which the input coordinates must fall in. */
data class DisplayBounds(val width: Int, val height: Int)

/** Checks one input event against its display (guest-protocol.md §9, input.md §9). */
object InputValidator {
    /** At most this many events in one batch (guest-protocol.md §9). */
    const val MAXIMUM_EVENTS_PER_BATCH = 256

    /** Android's multi-touch limit: the pointer IDs are 0 to 9. */
    private const val MAXIMUM_POINTER_ID = 9

    /** Key codes are positive and fit a 16-bit range. Android's own key codes are far below it. */
    private const val MAXIMUM_KEY_CODE = 0xFFFF

    /**
     * Whether [event] may be injected on a display of [bounds]. A kind that is not set is never
     * valid.
     */
    fun isValid(event: InputEvent, bounds: DisplayBounds): Boolean =
        when (event.kindCase) {
            InputEvent.KindCase.TOUCH -> {
                val touch = event.touch
                touch.phase != TouchPhase.TOUCH_PHASE_UNSPECIFIED &&
                    touch.phase != TouchPhase.UNRECOGNIZED &&
                    touch.pointerId in 0..MAXIMUM_POINTER_ID &&
                    inside(touch.x, touch.y, bounds)
            }
            InputEvent.KindCase.MOUSE -> {
                val mouse = event.mouse
                mouse.action != MouseAction.MOUSE_ACTION_UNSPECIFIED &&
                    mouse.action != MouseAction.UNRECOGNIZED &&
                    inside(mouse.x, mouse.y, bounds)
            }
            InputEvent.KindCase.SCROLL -> {
                val scroll = event.scroll
                inside(scroll.x, scroll.y, bounds) &&
                    scroll.vscroll.isFinite() &&
                    scroll.hscroll.isFinite()
            }
            InputEvent.KindCase.KEY -> {
                val key = event.key
                key.action != KeyAction.KEY_ACTION_UNSPECIFIED &&
                    key.action != KeyAction.UNRECOGNIZED &&
                    key.keyCode in 1..MAXIMUM_KEY_CODE &&
                    key.repeatCount >= 0
            }
            InputEvent.KindCase.LONG_PRESS -> inside(event.longPress.x, event.longPress.y, bounds)
            InputEvent.KindCase.CANCEL_ALL -> true
            else -> false
        }

    private fun inside(x: Float, y: Float, bounds: DisplayBounds): Boolean =
        x.isFinite() && y.isFinite() && x >= 0f && y >= 0f && x < bounds.width && y < bounds.height
}

/**
 * The input stream of the agent (guest-protocol.md §9). A batch is validated against its display,
 * and the invalid events are dropped and counted. The stream is not closed for them. The valid
 * events are queued on the `apkrun-input` thread, in order, so the reader of the socket never waits
 * for an injection. An ack is sent after its batch has been injected (input.md §8).
 */
class InputService(
    private val boundsOf: (Int) -> DisplayBounds?,
    private val injector: InputInjector,
    /** Runs a task on the `apkrun-input` thread, in the order that tasks are posted. */
    private val post: (() -> Unit) -> Unit,
    private val nanoTime: () -> Long = System::nanoTime,
) {
    private var batches = 0L
    private var injected = 0L
    private var rejected = 0L

    /**
     * The input connection that owns the open gestures (input.md §7.3). A connection that closes
     * cancels the gestures only while it still owns them, so a late close never cancels the gesture
     * of a newer connection.
     */
    private var owner: Any? = null

    /**
     * Validates [batch] from the input connection [stream], and queues its valid events for
     * injection. It returns without waiting for the injection. When the host asked for an ack, it
     * is passed to [sendAck] after the batch has been injected (guest-protocol.md §9).
     */
    fun submit(stream: Any, batch: InputBatch, sendAck: (InputAck) -> Unit) {
        val received = nanoTime()
        val events = batch.eventsList
        val bounds = boundsOf(batch.displayId)
        val valid: List<InputEvent> =
            if (bounds == null || events.size > InputValidator.MAXIMUM_EVENTS_PER_BATCH) {
                emptyList()
            } else {
                events.filter { InputValidator.isValid(it, bounds) }
            }
        val invalid = events.size - valid.size
        if (claim(stream, invalid)) {
            // The previous connection's gestures are cancelled before this batch is injected.
            post { record(injectOrDrop(0) { injector.cancelAll() }) }
        }
        val firstHostTimeNanos = events.firstOrNull()?.hostTimeNanos ?: 0L
        post {
            val outcome =
                injectOrDrop(valid.size) {
                    injector.injectBatch(batch.displayId, firstHostTimeNanos, valid)
                }
            record(outcome)
            if (batch.ackRequested) {
                val micros = ((nanoTime() - received) / 1_000L).coerceIn(0L, MAXIMUM_MICROS)
                sendAck(
                    InputAck.newBuilder()
                        .setBatchSeq(batch.batchSeq)
                        .setReceiveToInjectMicros(micros.toInt())
                        .setRejectedEvents(invalid + outcome.dropped)
                        .build()
                )
            }
        }
    }

    /**
     * The input connection [stream] closed. Its open gestures are cancelled, unless another
     * connection has taken them over (input.md §7.3).
     */
    fun streamClosed(stream: Any) {
        if (release(stream)) {
            post { record(injectOrDrop(0) { injector.cancelAll() }) }
        }
    }

    /** Cancels every open gesture when the control session closes (guest-protocol.md §5.4). */
    fun resetState() {
        post { record(injectOrDrop(0) { injector.cancelAll() }) }
    }

    /** Releases the gestures of a display that was removed (input.md §7.3). */
    fun displayRemoved(displayId: Int) {
        post { record(injectOrDrop(0) { injector.displayRemoved(displayId) }) }
    }

    /** The counters of `Health.input` (guest-protocol.md §7.4). */
    @Synchronized
    fun counters(): InputCounters =
        InputCounters.newBuilder()
            .setBatches(batches)
            .setEventsInjected(injected)
            .setEventsRejected(rejected)
            .build()

    /**
     * Counts a batch and takes its ownership for [stream]. Returns true when another connection
     * owned the gestures before, so that its gestures must be cancelled.
     */
    @Synchronized
    private fun claim(stream: Any, invalid: Int): Boolean {
        batches += 1
        rejected += invalid
        val previous = owner
        owner = stream
        return previous != null && previous !== stream
    }

    @Synchronized
    private fun release(stream: Any): Boolean {
        if (owner !== stream) {
            return false
        }
        owner = null
        return true
    }

    @Synchronized
    private fun record(outcome: BatchOutcome) {
        injected += outcome.injected
        rejected += outcome.dropped
    }

    /**
     * Runs [work] on the injector thread. A failure that escapes the injector is logged, and the
     * events of the batch count as dropped, so the ack and the counters still agree.
     */
    private fun injectOrDrop(droppedOnFailure: Int, work: () -> BatchOutcome): BatchOutcome =
        try {
            work()
        } catch (error: Exception) {
            AgentLog.error("input: a batch failed in the injector", error)
            BatchOutcome(0, droppedOnFailure)
        }

    private companion object {
        /** The largest value of the uint32 `receive_to_inject_micros`. */
        const val MAXIMUM_MICROS = 0xFFFF_FFFFL
    }
}
