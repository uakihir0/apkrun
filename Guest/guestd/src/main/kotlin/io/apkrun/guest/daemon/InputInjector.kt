package io.apkrun.guest.daemon

import android.view.InputDevice
import android.view.MotionEvent
import io.apkrun.guest.protocol.v1.InputEvent
import io.apkrun.guest.protocol.v1.KeyAction
import io.apkrun.guest.protocol.v1.KeyEvent
import io.apkrun.guest.protocol.v1.MouseAction
import io.apkrun.guest.protocol.v1.MouseEvent
import io.apkrun.guest.protocol.v1.ScrollEvent
import io.apkrun.guest.protocol.v1.TouchEvent
import io.apkrun.guest.protocol.v1.TouchPhase
import io.apkrun.guest.runtime.AgentLog

/**
 * The codes of an input failure. They are logged with the domain `InputFailure` and never with
 * event data (AGENTS §8).
 */
enum class InputFailureCode {
    /** `InputEvent.setDisplayId` is missing on this image (decision D7). */
    SET_DISPLAY_ID_UNAVAILABLE,

    /** The call of `InputEvent.setDisplayId` failed. */
    SET_DISPLAY_ID_FAILED,

    /** `MotionEvent.setActionButton` is missing on this image. */
    SET_ACTION_BUTTON_UNAVAILABLE,

    /** `MotionEvent.obtain` or `setActionButton` failed. */
    EVENT_NOT_BUILT,
}

/**
 * A failure that stops a batch, because the framework cannot take the events at all. The rest of
 * the batch is dropped and counted.
 */
class InputFailure(val code: InputFailureCode, cause: Throwable? = null) :
    RuntimeException(code.name, cause)

/** What one batch did: the events the framework accepted, and the events that did not reach it. */
data class BatchOutcome(val injected: Int, val dropped: Int)

/** The open touch gesture of one display: its pointer, its DOWN time, and its last position. */
private class TouchGesture(val pointerId: Int, val downTime: Long, var x: Float, var y: Float)

/**
 * The open mouse gesture of one display: from its first press to the release of its last button.
 */
private class MouseGesture(val downTime: Long, var x: Float, var y: Float) {
    /** The MotionEvent button bits that are down. */
    var buttons = 0
}

/**
 * The gesture state of one display (input.md §7.3). It changes only after the framework accepted
 * the event, so it always matches what Android has seen.
 */
private class DisplayGestures {
    var touch: TouchGesture? = null
    var mouse: MouseGesture? = null
    var hovering = false
    var hoverX = 0f
    var hoverY = 0f

    /** The keys that are down, by Android key code. */
    val keys = LinkedHashMap<Int, KeyPress>()
}

/**
 * A key that is down: the time of its DOWN, which its events keep as their down time, and the meta
 * state of its last event, which its release uses.
 */
private class KeyPress(val downTime: Long, var metaState: Int)

/** The counts of one batch, filled while it is planned and injected. */
private class Tally {
    var injected = 0
    var dropped = 0

    /** The hover events that were dropped by [InputInjector.hostHover] (they are in [dropped]). */
    var hoverSkipped = 0
}

/**
 * A batch spans a few milliseconds. A larger host time gap means a broken host clock, so the offset
 * of an event is clamped to this value.
 */
private const val MAXIMUM_OFFSET_NANOS = 1_000_000_000L
private const val NANOS_PER_MILLI = 1_000_000L

/** Whether [button] is exactly one MotionEvent button bit. */
private fun isSingleButton(button: Int): Boolean = button > 0 && (button and (button - 1)) == 0

/** Mouse button events have pressure 1 while a button is down, and 0 when none is. */
private fun pressureOf(buttonState: Int): Float = if (buttonState != 0) 1f else 0f

/**
 * The guest input injector (input.md §4.1, §7.3, guest-components.md §6.3). It plans the
 * MotionEvents of the input stream and injects them. The planner is plain Kotlin, and the framework
 * is reached through [factory] and [sink], so the JVM tests check every field.
 *
 * It runs on the `apkrun-input` thread only, so its state needs no lock. Its rules:
 * - A touch gesture is DOWN, MOVE, UP, or CANCEL on one pointer. A DOWN while a gesture is open
 *   cancels the open gesture, and the DOWN itself is dropped as an error.
 * - A mouse gesture opens with ACTION_DOWN at its first button press, and each press and release is
 *   an ACTION_BUTTON_PRESS or ACTION_BUTTON_RELEASE. The gesture closes with ACTION_UP when no
 *   button is down.
 * - Scroll stands alone. A key is a KeyEvent on the virtual keyboard (#025). A DOWN while the key
 *   is down is a repeat when its repeat count is above zero, and otherwise releases the open press
 *   and is dropped. An UP without an open press is dropped. A long press is dropped and counted,
 *   because it is not injected in this build (decision D6).
 * - A hover event is dropped while a touch or a mouse button gesture is open on its display,
 *   because Android refuses the mixed event. An unbalanced hover enter or exit is dropped too. Both
 *   are counted (see [hostHover]).
 * - An event that does not fit the open gesture is dropped and counted.
 * - A refused event is counted and does not change the gesture state.
 */
class InputInjector(
    private val factory: MotionEventFactory,
    private val sink: InjectionSink,
    private val keyFactory: KeyEventFactory = AndroidKeyEventFactory,
    private val uptimeMillis: () -> Long,
) {
    private val displays = HashMap<Int, DisplayGestures>()
    private var lastEventTime = Long.MIN_VALUE

    /**
     * Injects the [events] of one batch on [displayId], in order. [firstHostTimeNanos] is the host
     * time of the batch's first event, and the events keep their spacing from it (input.md §8).
     */
    fun injectBatch(
        displayId: Int,
        firstHostTimeNanos: Long,
        events: List<InputEvent>,
    ): BatchOutcome {
        if (events.isEmpty()) {
            return BatchOutcome(0, 0)
        }
        val tally = Tally()
        val base = uptimeMillis()
        val gestures = displays.getOrPut(displayId) { DisplayGestures() }
        var unsupported = 0
        var index = 0
        try {
            while (index < events.size) {
                val event = events[index]
                val time = eventTime(base, firstHostTimeNanos, event.hostTimeNanos)
                when (event.kindCase) {
                    InputEvent.KindCase.TOUCH ->
                        touch(displayId, gestures, event.touch, time, tally)
                    InputEvent.KindCase.MOUSE ->
                        mouse(displayId, gestures, event.mouse, time, tally)
                    InputEvent.KindCase.SCROLL ->
                        scroll(displayId, gestures, event.scroll, time, tally)
                    InputEvent.KindCase.KEY -> key(displayId, gestures, event.key, time, tally)
                    InputEvent.KindCase.CANCEL_ALL -> releaseAll(time, tally)
                    InputEvent.KindCase.LONG_PRESS -> {
                        unsupported += 1
                        tally.dropped += 1
                    }
                    else -> tally.dropped += 1
                }
                index += 1
            }
        } catch (failure: InputFailure) {
            AgentLog.error(
                "input: a batch was dropped: domain=InputFailure code=${failure.code.name}"
            )
            tally.dropped += events.size - index
        }
        if (unsupported > 0) {
            AgentLog.info(
                "input: dropped $unsupported long-press events (not injected in this build)"
            )
        }
        if (tally.hoverSkipped > 0) {
            AgentLog.info(
                "input: dropped ${tally.hoverSkipped} hover events (a gesture was open, or the hover enter and exit were not balanced)"
            )
        }
        return BatchOutcome(tally.injected, tally.dropped)
    }

    /** Releases the open gesture of every display: CANCEL, button releases, and UP (§7.3). */
    fun cancelAll(): BatchOutcome {
        val tally = Tally()
        try {
            releaseAll(now(), tally)
        } catch (failure: InputFailure) {
            AgentLog.error(
                "input: the open gestures were not all released: domain=InputFailure code=${failure.code.name}"
            )
        }
        if (tally.injected > 0) {
            AgentLog.info("input: released the open gestures with ${tally.injected} events")
        }
        return BatchOutcome(tally.injected, tally.dropped)
    }

    /**
     * Releases the open gestures of [displayId] when the display is removed, and forgets the
     * display (§7.3).
     */
    fun displayRemoved(displayId: Int): BatchOutcome {
        val gestures = displays.remove(displayId) ?: return BatchOutcome(0, 0)
        val tally = Tally()
        try {
            releaseDisplay(displayId, gestures, now(), tally)
        } catch (failure: InputFailure) {
            AgentLog.error(
                "input: the gestures of a removed display were not all released: domain=InputFailure code=${failure.code.name}"
            )
        }
        return BatchOutcome(tally.injected, tally.dropped)
    }

    private fun touch(
        displayId: Int,
        gestures: DisplayGestures,
        touch: TouchEvent,
        time: Long,
        tally: Tally,
    ) {
        val open = gestures.touch
        when (touch.phase) {
            TouchPhase.TOUCH_PHASE_DOWN -> {
                if (open != null) {
                    // A DOWN while a gesture is open means that the stream lost an UP. The open
                    // gesture is cancelled, and this DOWN is an error that is dropped.
                    cancelTouch(displayId, gestures, time, tally)
                    tally.dropped += 1
                    return
                }
                val spec =
                    touchSpec(
                        MotionEvent.ACTION_DOWN,
                        time,
                        time,
                        touch.pointerId,
                        touch.x,
                        touch.y,
                    )
                if (send(displayId, spec, tally)) {
                    gestures.touch = TouchGesture(touch.pointerId, time, touch.x, touch.y)
                }
            }
            TouchPhase.TOUCH_PHASE_MOVE -> {
                if (open == null || open.pointerId != touch.pointerId) {
                    tally.dropped += 1
                    return
                }
                val spec =
                    touchSpec(
                        MotionEvent.ACTION_MOVE,
                        open.downTime,
                        time,
                        open.pointerId,
                        touch.x,
                        touch.y,
                    )
                if (send(displayId, spec, tally)) {
                    open.x = touch.x
                    open.y = touch.y
                }
            }
            TouchPhase.TOUCH_PHASE_UP -> {
                if (open == null || open.pointerId != touch.pointerId) {
                    tally.dropped += 1
                    return
                }
                val spec =
                    touchSpec(
                        MotionEvent.ACTION_UP,
                        open.downTime,
                        time,
                        open.pointerId,
                        touch.x,
                        touch.y,
                    )
                if (send(displayId, spec, tally)) {
                    gestures.touch = null
                }
            }
            TouchPhase.TOUCH_PHASE_CANCEL -> {
                if (open == null || open.pointerId != touch.pointerId) {
                    tally.dropped += 1
                    return
                }
                cancelTouch(displayId, gestures, time, tally)
            }
            else -> tally.dropped += 1
        }
    }

    private fun mouse(
        displayId: Int,
        gestures: DisplayGestures,
        mouse: MouseEvent,
        time: Long,
        tally: Tally,
    ) {
        when (mouse.action) {
            MouseAction.MOUSE_ACTION_HOVER_ENTER ->
                hostHover(
                    displayId,
                    gestures,
                    MotionEvent.ACTION_HOVER_ENTER,
                    mouse,
                    time,
                    tally,
                    hovering = true,
                )
            MouseAction.MOUSE_ACTION_HOVER_MOVE ->
                hostHover(
                    displayId,
                    gestures,
                    MotionEvent.ACTION_HOVER_MOVE,
                    mouse,
                    time,
                    tally,
                    hovering = true,
                )
            MouseAction.MOUSE_ACTION_HOVER_EXIT ->
                hostHover(
                    displayId,
                    gestures,
                    MotionEvent.ACTION_HOVER_EXIT,
                    mouse,
                    time,
                    tally,
                    hovering = false,
                )
            MouseAction.MOUSE_ACTION_PRESS -> press(displayId, gestures, mouse, time, tally)
            MouseAction.MOUSE_ACTION_RELEASE -> release(displayId, gestures, mouse, time, tally)
            else -> tally.dropped += 1
        }
    }

    /**
     * A hover event from the host. Android refuses a hover event while a touch or a mouse button
     * gesture is open on the display, and the host translator holds hover during a gesture, so this
     * is the last check. Such an event is dropped and counted. An enter with a hover already open,
     * and an exit with none open, are dropped too, so the enters and exits stay balanced. The
     * teardown in [releaseDisplay] does not come through here, because it runs after the gestures
     * are closed.
     */
    private fun hostHover(
        displayId: Int,
        gestures: DisplayGestures,
        action: Int,
        mouse: MouseEvent,
        time: Long,
        tally: Tally,
        hovering: Boolean,
    ) {
        val gestureOpen = gestures.touch != null || gestures.mouse != null
        val unbalanced =
            when (action) {
                MotionEvent.ACTION_HOVER_ENTER -> gestures.hovering
                MotionEvent.ACTION_HOVER_EXIT -> !gestures.hovering
                else -> false
            }
        if (gestureOpen || unbalanced) {
            tally.dropped += 1
            tally.hoverSkipped += 1
            return
        }
        hover(displayId, gestures, action, mouse.x, mouse.y, time, tally, hovering)
    }

    private fun hover(
        displayId: Int,
        gestures: DisplayGestures,
        action: Int,
        x: Float,
        y: Float,
        time: Long,
        tally: Tally,
        hovering: Boolean,
    ) {
        if (send(displayId, mouseSpec(action, time, time, x, y), tally)) {
            gestures.hovering = hovering
            gestures.hoverX = x
            gestures.hoverY = y
        }
    }

    private fun press(
        displayId: Int,
        gestures: DisplayGestures,
        mouse: MouseEvent,
        time: Long,
        tally: Tally,
    ) {
        val button = mouse.button
        val pressed = gestures.mouse?.buttons ?: 0
        if (!isSingleButton(button) || (pressed and button) != 0) {
            tally.dropped += 1
            return
        }
        var gesture = gestures.mouse
        if (gesture == null) {
            // The first press of a gesture opens it with ACTION_DOWN.
            val down =
                mouseSpec(
                    MotionEvent.ACTION_DOWN,
                    time,
                    time,
                    mouse.x,
                    mouse.y,
                    buttonState = button,
                    pressure = 1f,
                )
            if (!send(displayId, down, tally)) {
                return
            }
            gesture = MouseGesture(time, mouse.x, mouse.y)
            gestures.mouse = gesture
        }
        val buttonState = gesture.buttons or button
        val spec =
            mouseSpec(
                MotionEvent.ACTION_BUTTON_PRESS,
                gesture.downTime,
                time,
                mouse.x,
                mouse.y,
                actionButton = button,
                buttonState = buttonState,
                pressure = 1f,
            )
        if (send(displayId, spec, tally)) {
            gesture.buttons = buttonState
            gesture.x = mouse.x
            gesture.y = mouse.y
        }
    }

    private fun release(
        displayId: Int,
        gestures: DisplayGestures,
        mouse: MouseEvent,
        time: Long,
        tally: Tally,
    ) {
        val button = mouse.button
        val gesture = gestures.mouse
        if (gesture == null || !isSingleButton(button) || (gesture.buttons and button) == 0) {
            tally.dropped += 1
            return
        }
        val remaining = gesture.buttons and button.inv()
        val spec =
            mouseSpec(
                MotionEvent.ACTION_BUTTON_RELEASE,
                gesture.downTime,
                time,
                mouse.x,
                mouse.y,
                actionButton = button,
                buttonState = remaining,
                pressure = pressureOf(remaining),
            )
        if (!send(displayId, spec, tally)) {
            return
        }
        gesture.buttons = remaining
        gesture.x = mouse.x
        gesture.y = mouse.y
        if (remaining == 0) {
            closeMouse(displayId, gestures, time, tally)
        }
    }

    /** Closes the mouse gesture with ACTION_UP. It is kept when the UP is refused. */
    private fun closeMouse(displayId: Int, gestures: DisplayGestures, time: Long, tally: Tally) {
        val gesture = gestures.mouse ?: return
        val up =
            mouseSpec(
                MotionEvent.ACTION_UP,
                gesture.downTime,
                time,
                gesture.x,
                gesture.y,
                buttonState = 0,
                pressure = 0f,
            )
        if (send(displayId, up, tally)) {
            gestures.mouse = null
        }
    }

    private fun scroll(
        displayId: Int,
        gestures: DisplayGestures,
        scroll: ScrollEvent,
        time: Long,
        tally: Tally,
    ) {
        val spec =
            mouseSpec(
                MotionEvent.ACTION_SCROLL,
                time,
                time,
                scroll.x,
                scroll.y,
                buttonState = gestures.mouse?.buttons ?: 0,
                axes =
                    mapOf(
                        MotionEvent.AXIS_VSCROLL to scroll.vscroll,
                        MotionEvent.AXIS_HSCROLL to scroll.hscroll,
                    ),
            )
        send(displayId, spec, tally)
    }

    /** Cancels the open touch gesture of a display with ACTION_CANCEL, at its last position. */
    private fun cancelTouch(displayId: Int, gestures: DisplayGestures, time: Long, tally: Tally) {
        val open = gestures.touch ?: return
        val spec =
            touchSpec(
                MotionEvent.ACTION_CANCEL,
                open.downTime,
                time,
                open.pointerId,
                open.x,
                open.y,
            )
        if (send(displayId, spec, tally)) {
            gestures.touch = null
        }
    }

    /**
     * Releases every pressed button of the mouse gesture, then closes it. Each step is attempted on
     * its own, so a refused release does not stop the others.
     */
    private fun releaseMouse(displayId: Int, gestures: DisplayGestures, time: Long, tally: Tally) {
        val gesture = gestures.mouse ?: return
        while (gesture.buttons != 0) {
            val button = gesture.buttons and -gesture.buttons
            val remaining = gesture.buttons and button.inv()
            val spec =
                mouseSpec(
                    MotionEvent.ACTION_BUTTON_RELEASE,
                    gesture.downTime,
                    time,
                    gesture.x,
                    gesture.y,
                    actionButton = button,
                    buttonState = remaining,
                    pressure = pressureOf(remaining),
                )
            if (!send(displayId, spec, tally)) {
                return
            }
            gesture.buttons = remaining
        }
        closeMouse(displayId, gestures, time, tally)
    }

    /** Releases the gestures of every display (`.cancelAll`). */
    private fun releaseAll(time: Long, tally: Tally) {
        for ((displayId, gestures) in displays) {
            releaseDisplay(displayId, gestures, time, tally)
        }
    }

    private fun releaseDisplay(
        displayId: Int,
        gestures: DisplayGestures,
        time: Long,
        tally: Tally,
    ) {
        cancelTouch(displayId, gestures, time, tally)
        releaseMouse(displayId, gestures, time, tally)
        if (gestures.hovering) {
            hover(
                displayId,
                gestures,
                MotionEvent.ACTION_HOVER_EXIT,
                gestures.hoverX,
                gestures.hoverY,
                time,
                tally,
                hovering = false,
            )
        }
        releaseKeys(displayId, gestures, time, tally)
    }

    /**
     * A key event of key mode (input.md §5.2, §7.3). A DOWN with a repeat count above zero repeats
     * the open press, and it keeps the press's down time. A DOWN without a count for a key that is
     * already down means that its UP was lost: the open press is released, and this DOWN is
     * dropped, as a touch DOWN is. A repeat or an UP with no open press is dropped.
     */
    private fun key(
        displayId: Int,
        gestures: DisplayGestures,
        key: KeyEvent,
        time: Long,
        tally: Tally,
    ) {
        val code = key.keyCode
        val metaState = key.metaState
        val open = gestures.keys[code]
        when (key.action) {
            KeyAction.KEY_ACTION_DOWN -> {
                if (key.repeatCount > 0) {
                    if (open == null) {
                        tally.dropped += 1
                        return
                    }
                    val spec =
                        keySpec(
                            android.view.KeyEvent.ACTION_DOWN,
                            open.downTime,
                            time,
                            code,
                            key.repeatCount,
                            metaState,
                        )
                    if (sendKey(displayId, spec, tally)) {
                        open.metaState = metaState
                    }
                    return
                }
                if (open != null) {
                    releaseKey(displayId, gestures, code, time, tally)
                    tally.dropped += 1
                    return
                }
                val spec =
                    keySpec(android.view.KeyEvent.ACTION_DOWN, time, time, code, 0, metaState)
                if (sendKey(displayId, spec, tally)) {
                    gestures.keys[code] = KeyPress(time, metaState)
                }
            }
            KeyAction.KEY_ACTION_UP -> {
                if (open == null) {
                    tally.dropped += 1
                    return
                }
                val spec =
                    keySpec(
                        android.view.KeyEvent.ACTION_UP,
                        open.downTime,
                        time,
                        code,
                        0,
                        metaState,
                    )
                if (sendKey(displayId, spec, tally)) {
                    gestures.keys.remove(code)
                }
            }
            else -> tally.dropped += 1
        }
    }

    /**
     * Releases the open press of [code] with ACTION_UP. The press is kept when the UP is refused.
     */
    private fun releaseKey(
        displayId: Int,
        gestures: DisplayGestures,
        code: Int,
        time: Long,
        tally: Tally,
    ) {
        val open = gestures.keys[code] ?: return
        val spec =
            keySpec(android.view.KeyEvent.ACTION_UP, open.downTime, time, code, 0, open.metaState)
        if (sendKey(displayId, spec, tally)) {
            gestures.keys.remove(code)
        }
    }

    /** Releases every key that is down on a display (`.cancelAll` and a removed display, §7.3). */
    private fun releaseKeys(displayId: Int, gestures: DisplayGestures, time: Long, tally: Tally) {
        for (code in gestures.keys.keys.toList()) {
            releaseKey(displayId, gestures, code, time, tally)
        }
    }

    private fun keySpec(
        action: Int,
        downTime: Long,
        time: Long,
        keyCode: Int,
        repeatCount: Int,
        metaState: Int,
    ): KeySpec =
        KeySpec(
            action = action,
            downTime = downTime,
            eventTime = time,
            keyCode = keyCode,
            repeatCount = repeatCount,
            metaState = metaState,
        )

    /**
     * Builds, tags, and injects one event, and returns whether the framework accepted it. A refusal
     * or a throw from the injection is counted as dropped. A failure of the build or of
     * `setDisplayId` throws [InputFailure], because the framework cannot take the events at all.
     */
    private fun send(displayId: Int, spec: MotionSpec, tally: Tally): Boolean =
        sendEvent(displayId, build(spec), tally)

    private fun sendKey(displayId: Int, spec: KeySpec, tally: Tally): Boolean =
        sendEvent(displayId, buildKey(spec), tally)

    /**
     * Sets the display of [event], injects it, and recycles it. The event is built by the caller.
     */
    private fun sendEvent(displayId: Int, event: Any, tally: Tally): Boolean {
        try {
            sink.setDisplayId(event, displayId)
            val accepted =
                try {
                    sink.inject(event)
                } catch (error: RuntimeException) {
                    AgentLog.warning(
                        "input: an event was not injected: ${error.javaClass.simpleName}"
                    )
                    false
                }
            if (accepted) {
                tally.injected += 1
                return true
            }
            tally.dropped += 1
            AgentLog.warning("input: the framework refused an event")
            return false
        } finally {
            sink.recycle(event)
        }
    }

    private fun buildKey(spec: KeySpec): Any =
        try {
            keyFactory.create(spec)
        } catch (failure: InputFailure) {
            throw failure
        } catch (error: RuntimeException) {
            throw InputFailure(InputFailureCode.EVENT_NOT_BUILT, error)
        }

    private fun build(spec: MotionSpec): Any =
        try {
            factory.create(spec)
        } catch (failure: InputFailure) {
            throw failure
        } catch (error: RuntimeException) {
            throw InputFailure(InputFailureCode.EVENT_NOT_BUILT, error)
        }

    /**
     * The event time of a host time: the base of the batch, plus the host time's offset from the
     * batch's first event. The times never go back, and the offset is clamped (see
     * [MAXIMUM_OFFSET_NANOS]).
     */
    private fun eventTime(base: Long, firstHostTimeNanos: Long, hostTimeNanos: Long): Long {
        val offsetNanos = (hostTimeNanos - firstHostTimeNanos).coerceIn(0L, MAXIMUM_OFFSET_NANOS)
        return monotonic(base + offsetNanos / NANOS_PER_MILLI)
    }

    private fun now(): Long = monotonic(uptimeMillis())

    private fun monotonic(time: Long): Long {
        lastEventTime = maxOf(time, lastEventTime)
        return lastEventTime
    }

    private fun touchSpec(
        action: Int,
        downTime: Long,
        time: Long,
        pointerId: Int,
        x: Float,
        y: Float,
    ): MotionSpec {
        val pressure =
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) 0f else 1f
        return MotionSpec(
            action = action,
            downTime = downTime,
            eventTime = time,
            source = InputDevice.SOURCE_TOUCHSCREEN,
            toolType = MotionEvent.TOOL_TYPE_FINGER,
            pointerId = pointerId,
            x = x,
            y = y,
            pressure = pressure,
            size = 1f,
            actionButton = 0,
            buttonState = 0,
            axes = emptyMap(),
        )
    }

    private fun mouseSpec(
        action: Int,
        downTime: Long,
        time: Long,
        x: Float,
        y: Float,
        actionButton: Int = 0,
        buttonState: Int = 0,
        pressure: Float = 0f,
        axes: Map<Int, Float> = emptyMap(),
    ): MotionSpec =
        MotionSpec(
            action = action,
            downTime = downTime,
            eventTime = time,
            source = InputDevice.SOURCE_MOUSE,
            toolType = MotionEvent.TOOL_TYPE_MOUSE,
            pointerId = 0,
            x = x,
            y = y,
            pressure = pressure,
            size = 0f,
            actionButton = actionButton,
            buttonState = buttonState,
            axes = axes,
        )
}
