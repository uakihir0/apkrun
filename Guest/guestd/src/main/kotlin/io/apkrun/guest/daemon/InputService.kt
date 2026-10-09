package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.InputAck
import io.apkrun.guest.protocol.v1.InputBatch
import io.apkrun.guest.protocol.v1.InputCounters
import io.apkrun.guest.protocol.v1.InputEvent
import io.apkrun.guest.protocol.v1.KeyAction
import io.apkrun.guest.protocol.v1.MouseAction
import io.apkrun.guest.protocol.v1.TouchPhase

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
 * and the invalid events are dropped and counted. The stream is not closed for them. Injection
 * arrives with #024 and #025, so `events_injected` stays 0 in this build.
 */
class InputService(private val boundsOf: (Int) -> DisplayBounds?) {
    private var batches = 0L
    private var rejected = 0L

    /** Validates [batch] and returns its ack when the host asked for one (guest-protocol.md §9). */
    @Synchronized
    fun submit(batch: InputBatch): InputAck? {
        batches += 1
        val bounds = boundsOf(batch.displayId)
        val dropped =
            when {
                bounds == null -> batch.eventsCount
                batch.eventsCount > InputValidator.MAXIMUM_EVENTS_PER_BATCH -> batch.eventsCount
                else -> batch.eventsList.count { !InputValidator.isValid(it, bounds) }
            }
        rejected += dropped
        if (!batch.ackRequested) {
            return null
        }
        return InputAck.newBuilder()
            .setBatchSeq(batch.batchSeq)
            .setReceiveToInjectMicros(0)
            .setRejectedEvents(dropped)
            .build()
    }

    /** Resets the input state when the control session closes (guest-protocol.md §5.4). */
    @Synchronized
    fun resetState() {
        // Gesture state is kept by the injector, which arrives with #024.
    }

    /** The counters of `Health.input` (guest-protocol.md §7.4). */
    @Synchronized
    fun counters(): InputCounters =
        InputCounters.newBuilder()
            .setBatches(batches)
            .setEventsInjected(0)
            .setEventsRejected(rejected)
            .build()
}
