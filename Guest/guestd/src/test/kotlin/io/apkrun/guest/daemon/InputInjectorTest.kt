package io.apkrun.guest.daemon

import android.view.InputDevice
import android.view.MotionEvent
import io.apkrun.guest.protocol.v1.CancelAll
import io.apkrun.guest.protocol.v1.InputAck
import io.apkrun.guest.protocol.v1.InputBatch
import io.apkrun.guest.protocol.v1.InputEvent
import io.apkrun.guest.protocol.v1.KeyAction
import io.apkrun.guest.protocol.v1.KeyEvent
import io.apkrun.guest.protocol.v1.LongPress
import io.apkrun.guest.protocol.v1.MouseAction
import io.apkrun.guest.protocol.v1.MouseEvent
import io.apkrun.guest.protocol.v1.ScrollEvent
import io.apkrun.guest.protocol.v1.TouchEvent
import io.apkrun.guest.protocol.v1.TouchPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the sink did with a framework event of the tests: its display and whether it was recycled.
 */
private open class RecordedEvent {
    var displayId: Int? = null
    var recycled = false
}

/** A motion event of the tests: the fields it was built from. */
private class FakeEvent(val spec: MotionSpec) : RecordedEvent()

/** A key event of the tests: the fields it was built from. */
private class FakeKeyEvent(val spec: KeySpec) : RecordedEvent()

/** Builds [FakeKeyEvent]s. [failure] makes every build throw. */
private class FakeKeyFactory : KeyEventFactory {
    var failure: RuntimeException? = null

    override fun create(spec: KeySpec): Any {
        failure?.let { throw it }
        return FakeKeyEvent(spec)
    }
}

/** Builds [FakeEvent]s, and records them. [failure] makes every build throw. */
private class FakeFactory : MotionEventFactory {
    val built = mutableListOf<FakeEvent>()
    var failure: RuntimeException? = null

    override fun create(spec: MotionSpec): Any {
        failure?.let { throw it }
        return FakeEvent(spec).also { built += it }
    }
}

/**
 * Records the framework calls. [displayIdFailure] makes setDisplayId throw. [refuse] and [throws]
 * decide which events the framework refuses, or makes the injection throw.
 */
private class FakeSink : InjectionSink {
    val displayIdCalls = mutableListOf<Int>()
    val injected = mutableListOf<FakeEvent>()
    val injectedKeys = mutableListOf<FakeKeyEvent>()
    /** Every injected event, motion and key, in the order of the injection. */
    val ordered = mutableListOf<RecordedEvent>()
    val injectedWithoutDisplay = mutableListOf<RecordedEvent>()
    var displayIdFailure: InputFailure? = null
    var refuse: (MotionSpec) -> Boolean = { false }
    var keyRefuse: (KeySpec) -> Boolean = { false }
    var throws: (MotionSpec) -> Boolean = { false }
    var recycled = 0

    override fun setDisplayId(event: Any, displayId: Int) {
        displayIdFailure?.let { throw it }
        (event as RecordedEvent).displayId = displayId
        displayIdCalls += displayId
    }

    override fun inject(event: Any): Boolean {
        val recorded = event as RecordedEvent
        if (recorded.displayId == null) {
            injectedWithoutDisplay += recorded
        }
        if (recorded is FakeKeyEvent) {
            if (keyRefuse(recorded.spec)) {
                return false
            }
            injectedKeys += recorded
            ordered += recorded
            return true
        }
        val fake = recorded as FakeEvent
        if (throws(fake.spec)) {
            throw RuntimeException("the framework threw")
        }
        if (refuse(fake.spec)) {
            return false
        }
        injected += fake
        ordered += fake
        return true
    }

    override fun recycle(event: Any) {
        (event as RecordedEvent).recycled = true
        recycled += 1
    }
}

/** One injector with a fake framework and a clock that the test moves. */
private class Harness {
    var clock = 1_000L
    val factory = FakeFactory()
    val keyFactory = FakeKeyFactory()
    val sink = FakeSink()
    val injector = InputInjector(factory, sink, keyFactory) { clock }

    val specs: List<MotionSpec>
        get() = sink.injected.map { it.spec }

    val actions: List<Int>
        get() = specs.map { it.action }

    val keySpecs: List<KeySpec>
        get() = sink.injectedKeys.map { it.spec }
}

private fun touchEvent(
    phase: TouchPhase,
    x: Float = 10f,
    y: Float = 20f,
    hostNanos: Long = 0L,
    pointer: Int = 0,
): InputEvent =
    InputEvent.newBuilder()
        .setHostTimeNanos(hostNanos)
        .setTouch(TouchEvent.newBuilder().setPhase(phase).setPointerId(pointer).setX(x).setY(y))
        .build()

private fun mouseEvent(
    action: MouseAction,
    button: Int = 0,
    x: Float = 30f,
    y: Float = 40f,
    hostNanos: Long = 0L,
): InputEvent =
    InputEvent.newBuilder()
        .setHostTimeNanos(hostNanos)
        .setMouse(MouseEvent.newBuilder().setAction(action).setButton(button).setX(x).setY(y))
        .build()

private fun scrollEvent(vscroll: Float, hscroll: Float, hostNanos: Long = 0L): InputEvent =
    InputEvent.newBuilder()
        .setHostTimeNanos(hostNanos)
        .setScroll(
            ScrollEvent.newBuilder().setX(50f).setY(60f).setVscroll(vscroll).setHscroll(hscroll)
        )
        .build()

private fun keyEvent(
    hostNanos: Long = 0L,
    action: KeyAction = KeyAction.KEY_ACTION_DOWN,
    keyCode: Int = 66,
    metaState: Int = 0,
    repeatCount: Int = 0,
): InputEvent =
    InputEvent.newBuilder()
        .setHostTimeNanos(hostNanos)
        .setKey(
            KeyEvent.newBuilder()
                .setAction(action)
                .setKeyCode(keyCode)
                .setMetaState(metaState)
                .setRepeatCount(repeatCount)
        )
        .build()

private fun longPressEvent(hostNanos: Long = 0L): InputEvent =
    InputEvent.newBuilder()
        .setHostTimeNanos(hostNanos)
        .setLongPress(LongPress.newBuilder().setX(10f).setY(10f))
        .build()

private fun cancelAllEvent(hostNanos: Long = 0L): InputEvent =
    InputEvent.newBuilder()
        .setHostTimeNanos(hostNanos)
        .setCancelAll(CancelAll.getDefaultInstance())
        .build()

class InputInjectorTest {
    private val touchscreen = InputDevice.SOURCE_TOUCHSCREEN
    private val mouse = InputDevice.SOURCE_MOUSE

    @Test
    fun aTouchGestureIsDownMoveAndUpOnTheTouchscreen() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                5_000_000_000L,
                listOf(
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 100f, 200f, 5_000_000_000L),
                    touchEvent(TouchPhase.TOUCH_PHASE_MOVE, 110f, 210f, 5_016_000_000L),
                    touchEvent(TouchPhase.TOUCH_PHASE_UP, 110f, 210f, 5_032_000_000L),
                ),
            )

        assertEquals(BatchOutcome(3, 0), outcome)
        assertEquals(
            listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE, MotionEvent.ACTION_UP),
            harness.actions,
        )
        for (spec in harness.specs) {
            assertEquals(touchscreen, spec.source)
            assertEquals(MotionEvent.TOOL_TYPE_FINGER, spec.toolType)
            assertEquals(0, spec.pointerId)
            assertEquals(0, spec.buttonState)
            assertEquals(0, spec.actionButton)
        }
        assertEquals(listOf(1f, 1f, 0f), harness.specs.map { it.pressure })
        assertEquals(listOf(100f, 110f, 110f), harness.specs.map { it.x })
        assertEquals(listOf(200f, 210f, 210f), harness.specs.map { it.y })
        assertEquals(listOf(1_000L, 1_000L, 1_000L), harness.specs.map { it.downTime })
        assertEquals(listOf(1_000L, 1_016L, 1_032L), harness.specs.map { it.eventTime })
        assertEquals(listOf(0, 0, 0), harness.sink.displayIdCalls)
        assertEquals(3, harness.sink.recycled)
    }

    @Test
    fun theDownTimeOfAGestureIsKeptAcrossBatches() {
        val harness = Harness()
        harness.injector.injectBatch(0, 0L, listOf(touchEvent(TouchPhase.TOUCH_PHASE_DOWN)))
        harness.clock = 1_500L
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                touchEvent(TouchPhase.TOUCH_PHASE_MOVE, hostNanos = 0L),
                touchEvent(TouchPhase.TOUCH_PHASE_UP, hostNanos = 0L),
            ),
        )

        assertEquals(listOf(1_000L, 1_000L, 1_000L), harness.specs.map { it.downTime })
        assertEquals(listOf(1_000L, 1_500L, 1_500L), harness.specs.map { it.eventTime })
    }

    @Test
    fun aHostGapLargerThanTheMaximumIsClamped() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                touchEvent(TouchPhase.TOUCH_PHASE_DOWN, hostNanos = 0L),
                touchEvent(TouchPhase.TOUCH_PHASE_MOVE, hostNanos = 5_000_000_000L),
            ),
        )

        assertEquals(listOf(1_000L, 2_000L), harness.specs.map { it.eventTime })
    }

    @Test
    fun cancelAllCancelsAnOpenTouchAtItsLastPosition() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 10f, 10f),
                touchEvent(TouchPhase.TOUCH_PHASE_MOVE, 120f, 220f),
            ),
        )
        harness.clock = 1_200L
        val outcome = harness.injector.cancelAll()

        assertEquals(BatchOutcome(1, 0), outcome)
        assertEquals(MotionEvent.ACTION_CANCEL, harness.actions.last())
        val cancel = harness.specs.last()
        assertEquals(120f, cancel.x)
        assertEquals(220f, cancel.y)
        assertEquals(1_000L, cancel.downTime)
        assertEquals(1_200L, cancel.eventTime)

        // The gesture is closed, so a second cancel injects nothing.
        assertEquals(BatchOutcome(0, 0), harness.injector.cancelAll())
    }

    @Test
    fun aSecondDownClosesTheOpenGestureAndIsDropped() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 10f, 10f),
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 50f, 50f),
                    touchEvent(TouchPhase.TOUCH_PHASE_MOVE, 60f, 60f),
                ),
            )

        // The first DOWN is injected. The second DOWN cancels the open gesture and is dropped.
        // The MOVE has no open gesture, so it is dropped too.
        assertEquals(BatchOutcome(2, 2), outcome)
        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL), harness.actions)
        assertEquals(10f, harness.specs.last().x)
    }

    @Test
    fun aMoveUpOrCancelWithoutAGestureIsDropped() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    touchEvent(TouchPhase.TOUCH_PHASE_MOVE),
                    touchEvent(TouchPhase.TOUCH_PHASE_UP),
                    touchEvent(TouchPhase.TOUCH_PHASE_CANCEL),
                ),
            )

        assertEquals(BatchOutcome(0, 3), outcome)
        assertTrue(harness.specs.isEmpty())
    }

    @Test
    fun hoverEnterMoveAndExitHaveTheMouseFields() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_ENTER, x = 30f, y = 40f),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_MOVE, x = 31f, y = 41f),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_EXIT, x = 32f, y = 42f),
                ),
            )

        assertEquals(BatchOutcome(3, 0), outcome)
        assertEquals(
            listOf(
                MotionEvent.ACTION_HOVER_ENTER,
                MotionEvent.ACTION_HOVER_MOVE,
                MotionEvent.ACTION_HOVER_EXIT,
            ),
            harness.actions,
        )
        for (spec in harness.specs) {
            assertEquals(mouse, spec.source)
            assertEquals(MotionEvent.TOOL_TYPE_MOUSE, spec.toolType)
            assertEquals(0f, spec.pressure)
            assertEquals(0, spec.buttonState)
        }
        assertEquals(listOf(30f, 31f, 32f), harness.specs.map { it.x })
        assertEquals(listOf(40f, 41f, 42f), harness.specs.map { it.y })
    }

    @Test
    fun aSecondaryPressAndReleaseIsDownButtonPressButtonReleaseUp() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_SECONDARY),
                    mouseEvent(MouseAction.MOUSE_ACTION_RELEASE, MotionEvent.BUTTON_SECONDARY),
                ),
            )

        assertEquals(BatchOutcome(4, 0), outcome)
        assertEquals(
            listOf(
                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_BUTTON_PRESS,
                MotionEvent.ACTION_BUTTON_RELEASE,
                MotionEvent.ACTION_UP,
            ),
            harness.actions,
        )
        val specs = harness.specs
        assertEquals(List(4) { mouse }, specs.map { it.source })
        assertTrue(specs.all { it.toolType == MotionEvent.TOOL_TYPE_MOUSE })
        assertEquals(
            listOf(0, MotionEvent.BUTTON_SECONDARY, MotionEvent.BUTTON_SECONDARY, 0),
            specs.map { it.actionButton },
        )
        assertEquals(
            listOf(MotionEvent.BUTTON_SECONDARY, MotionEvent.BUTTON_SECONDARY, 0, 0),
            specs.map { it.buttonState },
        )
        assertEquals(listOf(1f, 1f, 0f, 0f), specs.map { it.pressure })
        assertEquals(listOf(1_000L), specs.map { it.downTime }.distinct())
    }

    @Test
    fun aGestureWithTwoButtonsCloseOnlyAfterTheLastRelease() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_SECONDARY),
                    mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_TERTIARY),
                    mouseEvent(MouseAction.MOUSE_ACTION_RELEASE, MotionEvent.BUTTON_SECONDARY),
                    mouseEvent(MouseAction.MOUSE_ACTION_RELEASE, MotionEvent.BUTTON_TERTIARY),
                ),
            )

        assertEquals(BatchOutcome(6, 0), outcome)
        assertEquals(
            listOf(
                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_BUTTON_PRESS,
                MotionEvent.ACTION_BUTTON_PRESS,
                MotionEvent.ACTION_BUTTON_RELEASE,
                MotionEvent.ACTION_BUTTON_RELEASE,
                MotionEvent.ACTION_UP,
            ),
            harness.actions,
        )
        // The state after each release leaves the other button down, until the last one.
        assertEquals(
            listOf(
                MotionEvent.BUTTON_SECONDARY,
                MotionEvent.BUTTON_SECONDARY,
                MotionEvent.BUTTON_SECONDARY or MotionEvent.BUTTON_TERTIARY,
                MotionEvent.BUTTON_TERTIARY,
                0,
                0,
            ),
            harness.specs.map { it.buttonState },
        )
    }

    @Test
    fun aRepeatedPressAndAReleaseWithoutAPressAreDropped() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_SECONDARY),
                    mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_SECONDARY),
                    mouseEvent(MouseAction.MOUSE_ACTION_RELEASE, MotionEvent.BUTTON_TERTIARY),
                ),
            )

        assertEquals(BatchOutcome(2, 2), outcome)
    }

    @Test
    fun cancelAllReleasesEveryPressedMouseButtonAndClosesTheGesture() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_SECONDARY),
                mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_TERTIARY),
            ),
        )
        harness.clock = 1_100L
        val outcome = harness.injector.cancelAll()

        assertEquals(BatchOutcome(3, 0), outcome)
        val released = harness.specs.takeLast(3)
        assertEquals(
            listOf(
                MotionEvent.ACTION_BUTTON_RELEASE,
                MotionEvent.ACTION_BUTTON_RELEASE,
                MotionEvent.ACTION_UP,
            ),
            released.map { it.action },
        )
        assertEquals(
            listOf(MotionEvent.BUTTON_SECONDARY, MotionEvent.BUTTON_TERTIARY),
            released.take(2).map { it.actionButton },
        )
        assertEquals(listOf(MotionEvent.BUTTON_TERTIARY, 0, 0), released.map { it.buttonState })
        assertEquals(1_100L, released.last().eventTime)
        assertEquals(1_000L, released.last().downTime)
    }

    @Test
    fun cancelAllExitsAHoverThatIsEntered() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(mouseEvent(MouseAction.MOUSE_ACTION_HOVER_ENTER, x = 70f, y = 80f)),
        )
        harness.injector.cancelAll()

        assertEquals(
            listOf(MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_EXIT),
            harness.actions,
        )
        assertEquals(70f, harness.specs.last().x)
        assertEquals(80f, harness.specs.last().y)
    }

    @Test
    fun aHoverMoveDuringAnOpenTouchGestureIsNotInjectedAndIsCounted() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(mouseEvent(MouseAction.MOUSE_ACTION_HOVER_ENTER, x = 30f, y = 40f)),
        )
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 10f, 10f),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_MOVE, x = 31f, y = 41f),
                    touchEvent(TouchPhase.TOUCH_PHASE_MOVE, 12f, 12f),
                ),
            )

        assertEquals(BatchOutcome(2, 1), outcome)
        assertEquals(
            listOf(
                MotionEvent.ACTION_HOVER_ENTER,
                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_MOVE,
            ),
            harness.actions,
        )
        // The hover entered before the gesture is still open, so cancelAll exits it.
        harness.injector.cancelAll()
        assertEquals(MotionEvent.ACTION_HOVER_EXIT, harness.actions.last())
    }

    @Test
    fun aHoverMoveDuringAnOpenMouseButtonGestureIsNotInjected() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_SECONDARY),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_MOVE, x = 31f, y = 41f),
                    mouseEvent(MouseAction.MOUSE_ACTION_RELEASE, MotionEvent.BUTTON_SECONDARY),
                ),
            )

        assertEquals(BatchOutcome(4, 1), outcome)
        assertEquals(
            listOf(
                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_BUTTON_PRESS,
                MotionEvent.ACTION_BUTTON_RELEASE,
                MotionEvent.ACTION_UP,
            ),
            harness.actions,
        )
    }

    @Test
    fun aHoverMoveIsInjectedAgainAfterTheGestureIsReleased() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_ENTER, x = 30f, y = 40f),
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 10f, 10f),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_MOVE, x = 31f, y = 41f),
                    touchEvent(TouchPhase.TOUCH_PHASE_UP, 10f, 10f),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_MOVE, x = 32f, y = 42f),
                ),
            )

        assertEquals(BatchOutcome(4, 1), outcome)
        assertEquals(
            listOf(
                MotionEvent.ACTION_HOVER_ENTER,
                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_UP,
                MotionEvent.ACTION_HOVER_MOVE,
            ),
            harness.actions,
        )
        assertEquals(32f, harness.specs.last().x)
        assertEquals(42f, harness.specs.last().y)
    }

    @Test
    fun aGestureOnAnotherDisplayDoesNotHoldHoverOnThisOne() {
        val harness = Harness()
        harness.injector.injectBatch(1, 0L, listOf(touchEvent(TouchPhase.TOUCH_PHASE_DOWN)))
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(mouseEvent(MouseAction.MOUSE_ACTION_HOVER_MOVE, x = 31f, y = 41f)),
            )

        assertEquals(BatchOutcome(1, 0), outcome)
        assertEquals(MotionEvent.ACTION_HOVER_MOVE, harness.actions.last())
    }

    @Test
    fun aHoverExitWithNoOpenEnterIsSkipped() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_EXIT),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_ENTER),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_EXIT),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_EXIT),
                ),
            )

        assertEquals(BatchOutcome(2, 2), outcome)
        assertEquals(
            listOf(MotionEvent.ACTION_HOVER_ENTER, MotionEvent.ACTION_HOVER_EXIT),
            harness.actions,
        )
        // Nothing is open, so the cancel has no hover to exit.
        assertEquals(BatchOutcome(0, 0), harness.injector.cancelAll())
    }

    @Test
    fun aHoverEnterWhileAHoverIsOpenIsSkipped() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_ENTER),
                    mouseEvent(MouseAction.MOUSE_ACTION_HOVER_ENTER),
                ),
            )

        assertEquals(BatchOutcome(1, 1), outcome)
        assertEquals(listOf(MotionEvent.ACTION_HOVER_ENTER), harness.actions)
    }

    @Test
    fun cancelAllExitsAHoverWhileAGestureIsOpen() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                mouseEvent(MouseAction.MOUSE_ACTION_HOVER_ENTER, x = 70f, y = 80f),
                touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
            ),
        )
        val outcome = harness.injector.cancelAll()

        assertEquals(BatchOutcome(2, 0), outcome)
        assertEquals(
            listOf(
                MotionEvent.ACTION_HOVER_ENTER,
                MotionEvent.ACTION_DOWN,
                MotionEvent.ACTION_CANCEL,
                MotionEvent.ACTION_HOVER_EXIT,
            ),
            harness.actions,
        )
    }

    @Test
    fun aScrollHasTheVerticalAndHorizontalAxisValues() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(0, 0L, listOf(scrollEvent(vscroll = 1.5f, hscroll = -2f)))

        assertEquals(BatchOutcome(1, 0), outcome)
        val spec = harness.specs.single()
        assertEquals(MotionEvent.ACTION_SCROLL, spec.action)
        assertEquals(mouse, spec.source)
        assertEquals(MotionEvent.TOOL_TYPE_MOUSE, spec.toolType)
        assertEquals(50f, spec.x)
        assertEquals(60f, spec.y)
        assertEquals(
            mapOf(MotionEvent.AXIS_VSCROLL to 1.5f, MotionEvent.AXIS_HSCROLL to -2f),
            spec.axes,
        )
    }

    @Test
    fun aLongPressIsDroppedAndCounted() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    longPressEvent(),
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
                ),
            )

        assertEquals(BatchOutcome(1, 1), outcome)
        assertEquals(listOf(MotionEvent.ACTION_DOWN), harness.actions)
    }

    @Test
    fun theDisplayIsSetOnEveryEventBeforeItIsInjected() {
        val harness = Harness()
        harness.injector.injectBatch(
            2,
            0L,
            listOf(
                touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
                touchEvent(TouchPhase.TOUCH_PHASE_MOVE),
                touchEvent(TouchPhase.TOUCH_PHASE_UP),
            ),
        )

        assertEquals(listOf(2, 2, 2), harness.sink.displayIdCalls)
        assertEquals(3, harness.sink.injected.size)
        assertTrue(harness.sink.injectedWithoutDisplay.isEmpty())
        assertTrue(harness.sink.injected.all { it.displayId == 2 && it.recycled })
    }

    @Test
    fun aMissingDisplayIdMethodDropsTheBatch() {
        val harness = Harness()
        harness.sink.displayIdFailure = InputFailure(InputFailureCode.SET_DISPLAY_ID_UNAVAILABLE)
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
                    touchEvent(TouchPhase.TOUCH_PHASE_MOVE),
                    touchEvent(TouchPhase.TOUCH_PHASE_UP),
                ),
            )

        assertEquals(BatchOutcome(0, 3), outcome)
        assertTrue(harness.sink.injected.isEmpty())
    }

    @Test
    fun aRefusedInjectionIsCountedAndTheRestContinues() {
        val harness = Harness()
        harness.sink.refuse = { it.action == MotionEvent.ACTION_MOVE }
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
                    touchEvent(TouchPhase.TOUCH_PHASE_MOVE),
                    touchEvent(TouchPhase.TOUCH_PHASE_UP),
                ),
            )

        assertEquals(BatchOutcome(2, 1), outcome)
        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP), harness.actions)
    }

    @Test
    fun anInjectionThatThrowsIsCountedAndTheRestContinues() {
        val harness = Harness()
        harness.sink.throws = { it.action == MotionEvent.ACTION_MOVE }
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
                    touchEvent(TouchPhase.TOUCH_PHASE_MOVE),
                    touchEvent(TouchPhase.TOUCH_PHASE_UP),
                ),
            )

        assertEquals(BatchOutcome(2, 1), outcome)
        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP), harness.actions)
    }

    @Test
    fun aRefusedDownLeavesNoGestureOpen() {
        val harness = Harness()
        harness.sink.refuse = { it.action == MotionEvent.ACTION_DOWN }
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
                touchEvent(TouchPhase.TOUCH_PHASE_MOVE),
            ),
        )

        // The DOWN was refused, so the MOVE has no gesture to belong to and nothing is cancelled.
        assertTrue(harness.specs.isEmpty())
        assertEquals(BatchOutcome(0, 0), harness.injector.cancelAll())
    }

    @Test
    fun aFailedBuildDropsTheBatch() {
        val harness = Harness()
        harness.factory.failure = IllegalArgumentException("obtain refused the arguments")
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
                    touchEvent(TouchPhase.TOUCH_PHASE_UP),
                ),
            )

        assertEquals(BatchOutcome(0, 2), outcome)
        assertTrue(harness.sink.injected.isEmpty())
    }

    @Test
    fun aDisplayThatIsRemovedReleasesItsGesture() {
        val harness = Harness()
        harness.injector.injectBatch(0, 0L, listOf(touchEvent(TouchPhase.TOUCH_PHASE_DOWN)))
        val outcome = harness.injector.displayRemoved(0)

        assertEquals(BatchOutcome(1, 0), outcome)
        assertEquals(MotionEvent.ACTION_CANCEL, harness.actions.last())
        // The display is forgotten, so a later event on it has no gesture.
        assertEquals(
            BatchOutcome(0, 1),
            harness.injector.injectBatch(
                0,
                0L,
                listOf(touchEvent(TouchPhase.TOUCH_PHASE_UP)),
            ),
        )
        assertEquals(BatchOutcome(0, 0), harness.injector.displayRemoved(7))
    }

    @Test
    fun aCancelAllEventInABatchReleasesEveryDisplay() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                touchEvent(TouchPhase.TOUCH_PHASE_DOWN),
                mouseEvent(MouseAction.MOUSE_ACTION_PRESS, MotionEvent.BUTTON_SECONDARY),
            ),
        )
        harness.injector.injectBatch(1, 0L, listOf(touchEvent(TouchPhase.TOUCH_PHASE_DOWN)))
        val outcome = harness.injector.injectBatch(0, 0L, listOf(cancelAllEvent()))

        // Display 0 has a touch and a mouse press, display 1 has a touch: four releases.
        assertEquals(BatchOutcome(4, 0), outcome)
        assertEquals(
            listOf(MotionEvent.ACTION_CANCEL, MotionEvent.ACTION_CANCEL),
            harness.actions.filter { it == MotionEvent.ACTION_CANCEL },
        )
        assertTrue(harness.actions.contains(MotionEvent.ACTION_UP))
    }

    @Test
    fun theAckOfABatchCountsItsRejectedEventsAfterInjection() {
        val harness = Harness()
        val tasks = mutableListOf<() -> Unit>()
        val sent = mutableListOf<InputAck>()
        var nanos = 1_000_000L
        val service =
            InputService(
                boundsOf = { id -> if (id == 0) DisplayBounds(100, 100) else null },
                injector = harness.injector,
                post = { tasks += it },
                nanoTime = { nanos },
            )
        val batch =
            InputBatch.newBuilder()
                .setBatchSeq(5)
                .setDisplayId(0)
                .setAckRequested(true)
                .addAllEvents(
                    listOf(
                        touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 10f, 10f),
                        touchEvent(TouchPhase.TOUCH_PHASE_MOVE, 500f, 1f),
                        keyEvent(),
                    )
                )
                .build()
        service.submit(this, batch) { sent += it }

        // The batch is only queued: nothing is injected and no ack is sent yet.
        assertTrue(sent.isEmpty())
        assertTrue(harness.sink.injected.isEmpty())

        nanos += 250_000L
        tasks.forEach { it() }

        val ack = sent.single()
        assertEquals(5L, ack.batchSeq)
        assertEquals(250, ack.receiveToInjectMicros)
        // The MOVE is outside the display. The DOWN of the key is valid, and it is injected as a
        // key.
        assertEquals(1, ack.rejectedEvents)
        assertEquals(1, harness.sink.injected.size)
        assertEquals(1, harness.sink.injectedKeys.size)
        val counters = service.counters()
        assertEquals(1L, counters.batches)
        assertEquals(2L, counters.eventsInjected)
        assertEquals(1L, counters.eventsRejected)
    }

    @Test
    fun aBatchForAnUnknownDisplayDropsEveryEvent() {
        val harness = Harness()
        val sent = mutableListOf<InputAck>()
        val service =
            InputService(
                boundsOf = { id -> if (id == 0) DisplayBounds(100, 100) else null },
                injector = harness.injector,
                post = { it() },
            )
        val batch =
            InputBatch.newBuilder()
                .setBatchSeq(9)
                .setDisplayId(3)
                .setAckRequested(true)
                .addEvents(cancelAllEvent())
                .build()
        service.submit(this, batch) { sent += it }

        assertEquals(1, sent.single().rejectedEvents)
        assertTrue(harness.sink.injected.isEmpty())
    }

    @Test
    fun aBatchOverTheLimitDropsEveryEventAndSendsNoAckWithoutRequest() {
        val harness = Harness()
        val sent = mutableListOf<InputAck>()
        val service =
            InputService(
                boundsOf = { DisplayBounds(100, 100) },
                injector = harness.injector,
                post = { it() },
            )
        val events = List(InputValidator.MAXIMUM_EVENTS_PER_BATCH + 1) { cancelAllEvent() }
        service.submit(
            this,
            InputBatch.newBuilder().setBatchSeq(1).setDisplayId(0).addAllEvents(events).build(),
        ) {
            sent += it
        }

        assertTrue(sent.isEmpty())
        assertEquals(1L, service.counters().batches)
        assertEquals(
            InputValidator.MAXIMUM_EVENTS_PER_BATCH + 1L,
            service.counters().eventsRejected,
        )
    }

    @Test
    fun aClosedStreamCancelsItsGesturesOnlyWhileItOwnsThem() {
        val harness = Harness()
        val first = Any()
        val second = Any()
        val service =
            InputService(
                boundsOf = { DisplayBounds(100, 100) },
                injector = harness.injector,
                post = { it() },
            )
        fun batch(vararg events: InputEvent) =
            InputBatch.newBuilder().setDisplayId(0).addAllEvents(events.toList()).build()

        service.submit(first, batch(touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 10f, 10f))) {}
        // A second connection takes the input over. The first gesture is cancelled, and the MOVE
        // that follows has no gesture left.
        service.submit(second, batch(touchEvent(TouchPhase.TOUCH_PHASE_MOVE, 20f, 20f))) {}
        // The first connection closes late. It no longer owns anything, so nothing is cancelled.
        service.streamClosed(first)

        assertEquals(
            listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL),
            harness.actions,
        )
        assertEquals(2L, service.counters().eventsInjected)
        assertEquals(1L, service.counters().eventsRejected)

        service.streamClosed(second)
        assertEquals(2L, service.counters().eventsInjected)
    }

    @Test
    fun resetStateCancelsTheOpenGesture() {
        val harness = Harness()
        val service =
            InputService(
                boundsOf = { DisplayBounds(100, 100) },
                injector = harness.injector,
                post = { it() },
            )
        service.submit(
            this,
            InputBatch.newBuilder()
                .setDisplayId(0)
                .addEvents(touchEvent(TouchPhase.TOUCH_PHASE_DOWN))
                .build(),
        ) {}
        service.resetState()

        assertEquals(listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_CANCEL), harness.actions)
        assertEquals(2L, service.counters().eventsInjected)
    }
}

/**
 * Key mode on the injector (input.md §5.2, §7.3; #025). The base time is the uptime that the
 * harness starts at.
 */
class InputInjectorKeyTest {
    private val base = 1_000L
    private val androidDown = android.view.KeyEvent.ACTION_DOWN
    private val androidUp = android.view.KeyEvent.ACTION_UP

    @Test
    fun aKeyDownAndUpBuildKeyEventsOnTheDisplayWithTheirMetaState() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    keyEvent(hostNanos = 0L, keyCode = 29, metaState = 1),
                    keyEvent(
                        hostNanos = 1_000_000L,
                        action = KeyAction.KEY_ACTION_UP,
                        keyCode = 29,
                        metaState = 0,
                    ),
                ),
            )

        assertEquals(BatchOutcome(2, 0), outcome)
        assertEquals(
            listOf(
                KeySpec(androidDown, base, base, 29, 0, 1),
                KeySpec(androidUp, base, base + 1, 29, 0, 0),
            ),
            harness.keySpecs,
        )
        assertEquals(listOf(0, 0), harness.sink.displayIdCalls)
        assertTrue(harness.sink.injectedWithoutDisplay.isEmpty())
    }

    @Test
    fun repeatsKeepTheDownTimeAndNoUpComesBetweenThem() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                keyEvent(hostNanos = 0L, keyCode = 29),
                keyEvent(hostNanos = 10_000_000L, keyCode = 29, repeatCount = 1),
                keyEvent(hostNanos = 20_000_000L, keyCode = 29, repeatCount = 2),
                keyEvent(hostNanos = 30_000_000L, action = KeyAction.KEY_ACTION_UP, keyCode = 29),
            ),
        )

        assertEquals(
            listOf(androidDown, androidDown, androidDown, androidUp),
            harness.keySpecs.map { it.action },
        )
        assertEquals(listOf(0, 1, 2, 0), harness.keySpecs.map { it.repeatCount })
        assertEquals(listOf(base, base, base, base), harness.keySpecs.map { it.downTime })
        assertEquals(
            listOf(base, base + 10, base + 20, base + 30),
            harness.keySpecs.map { it.eventTime },
        )
    }

    @Test
    fun aDownWhileTheKeyIsDownReleasesThePressAndDropsItself() {
        // The UP of the press was lost. The press is released, the second DOWN is dropped, and the
        // UP that follows has no
        // press to end.
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    keyEvent(hostNanos = 0L, keyCode = 29),
                    keyEvent(hostNanos = 1L, keyCode = 29),
                    keyEvent(hostNanos = 2L, action = KeyAction.KEY_ACTION_UP, keyCode = 29),
                ),
            )

        assertEquals(BatchOutcome(2, 2), outcome)
        assertEquals(listOf(androidDown, androidUp), harness.keySpecs.map { it.action })
    }

    @Test
    fun anUpOrARepeatWithoutAPressIsDropped() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    keyEvent(hostNanos = 0L, action = KeyAction.KEY_ACTION_UP, keyCode = 29),
                    keyEvent(hostNanos = 1L, keyCode = 29, repeatCount = 1),
                ),
            )

        assertEquals(BatchOutcome(0, 2), outcome)
        assertTrue(harness.keySpecs.isEmpty())
    }

    @Test
    fun aRefusedDownIsNotOpen() {
        val harness = Harness()
        harness.sink.keyRefuse = { it.action == androidDown }
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    keyEvent(hostNanos = 0L, keyCode = 29),
                    keyEvent(hostNanos = 1L, action = KeyAction.KEY_ACTION_UP, keyCode = 29),
                ),
            )

        assertEquals(BatchOutcome(0, 2), outcome)
        assertTrue(harness.keySpecs.isEmpty())
    }

    @Test
    fun aRefusedUpKeepsThePressUntilCancelAllReleasesIt() {
        val harness = Harness()
        harness.sink.keyRefuse = { it.action == androidUp }
        val batch =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    keyEvent(hostNanos = 0L, keyCode = 29),
                    keyEvent(hostNanos = 1L, action = KeyAction.KEY_ACTION_UP, keyCode = 29),
                ),
            )
        assertEquals(BatchOutcome(1, 1), batch)

        harness.sink.keyRefuse = { false }
        assertEquals(BatchOutcome(1, 0), harness.injector.cancelAll())
        assertEquals(listOf(androidDown, androidUp), harness.keySpecs.map { it.action })
    }

    @Test
    fun cancelAllReleasesEachKeyWithTheMetaStateOfItsPress() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(keyEvent(hostNanos = 0L, keyCode = 29, metaState = 1)),
        )
        harness.clock += 5L

        assertEquals(BatchOutcome(1, 0), harness.injector.cancelAll())
        assertEquals(
            KeySpec(androidUp, base, base + 5, 29, 0, 1),
            harness.keySpecs.last(),
        )
    }

    @Test
    fun aRemovedDisplayReleasesOnlyItsKeys() {
        val harness = Harness()
        harness.injector.injectBatch(0, 0L, listOf(keyEvent(hostNanos = 0L, keyCode = 29)))
        harness.injector.injectBatch(1, 0L, listOf(keyEvent(hostNanos = 0L, keyCode = 30)))

        assertEquals(BatchOutcome(1, 0), harness.injector.displayRemoved(0))
        assertEquals(
            listOf(Pair(29, androidDown), Pair(30, androidDown), Pair(29, androidUp)),
            harness.keySpecs.map { Pair(it.keyCode, it.action) },
        )
        assertEquals(0, harness.sink.injectedKeys.last().displayId)

        assertEquals(BatchOutcome(1, 0), harness.injector.cancelAll())
        assertEquals(
            Pair(30, androidUp),
            harness.keySpecs.last().let { Pair(it.keyCode, it.action) },
        )
    }

    @Test
    fun keysAndTouchesKeepTheirOrderInTheBatch() {
        val harness = Harness()
        harness.injector.injectBatch(
            0,
            0L,
            listOf(
                touchEvent(TouchPhase.TOUCH_PHASE_DOWN, 10f, 10f),
                keyEvent(hostNanos = 1L, keyCode = 29),
                keyEvent(hostNanos = 2L, action = KeyAction.KEY_ACTION_UP, keyCode = 29),
                touchEvent(TouchPhase.TOUCH_PHASE_UP, 10f, 10f),
            ),
        )

        assertEquals(
            listOf(false, true, true, false),
            harness.sink.ordered.map { it is FakeKeyEvent },
        )
    }

    @Test
    fun anUnspecifiedKeyActionIsDropped() {
        val harness = Harness()
        val outcome =
            harness.injector.injectBatch(
                0,
                0L,
                listOf(
                    keyEvent(
                        hostNanos = 0L,
                        action = KeyAction.KEY_ACTION_UNSPECIFIED,
                        keyCode = 29,
                    )
                ),
            )

        assertEquals(BatchOutcome(0, 1), outcome)
        assertTrue(harness.keySpecs.isEmpty())
    }

    @Test
    fun aKeyThatCannotBeBuiltStopsTheBatchAndCountsTheRest() {
        val harness = Harness()
        harness.keyFactory.failure = RuntimeException("the framework refused the build")
        val outcome =
            harness.injector.injectBatch(0, 0L, listOf(keyEvent(hostNanos = 0L, keyCode = 29)))

        assertEquals(BatchOutcome(0, 1), outcome)
        assertTrue(harness.sink.injectedKeys.isEmpty())
    }
}
