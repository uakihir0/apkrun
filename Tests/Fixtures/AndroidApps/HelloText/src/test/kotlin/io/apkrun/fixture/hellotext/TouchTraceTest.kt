package io.apkrun.fixture.hellotext

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The bounded opt-in input trace state machine on the JVM; no Android runtime is needed. */
class TouchTraceTest {
    @Test
    fun debugSessionObserverTracksWhenCaptureAttachesAndDetachesTheTouchListener() {
        DebugTouchTraceSession.stopAndDrain()
        val states = mutableListOf<Boolean>()
        try {
            DebugTouchTraceSession.setCaptureStateObserver { states.add(it) }

            assertEquals(listOf(false), states)
            DebugTouchTraceSession.start()
            assertEquals(listOf(false, true), states)
            DebugTouchTraceSession.stopAndDrain()
            assertEquals(listOf(false, true, false), states)
        } finally {
            DebugTouchTraceSession.stopAndDrain()
            DebugTouchTraceSession.setCaptureStateObserver(null)
        }
    }

    @Test
    fun captureIsOffByDefaultAndIgnoresInputSamplesAndClicks() {
        val trace = TouchTrace(capacity = 4)

        assertFalse(trace.isCapturing)
        assertNull(
            trace.recordTouch(
                10,
                5,
                TouchTraceAction.DOWN.maskedValue,
                false,
                true,
                true,
                true,
                true,
            )
        )
        trace.recordPostDispatchPressed(
            input = TouchTraceInputToken(sequence = 1, captureToken = Any()),
            sampledAtUptimeMillis = 20,
            pressed = true,
        )
        assertNull(trace.recordClick(storedCounter = 1, saveSucceeded = true))

        val drain = trace.stopAndDrain()

        assertFalse(trace.isCapturing)
        assertTrue(drain.records.isEmpty())
        assertEquals(0L, drain.droppedRecordCount)
    }

    @Test
    fun startClearsAndDrainStopsAndReturnsOrderedRecords() {
        val trace = TouchTrace(capacity = 8)

        assertEquals(8, trace.start())
        val staleInput =
            trace.recordTouch(
                1,
                1,
                TouchTraceAction.DOWN.maskedValue,
                false,
                true,
                true,
                true,
                true,
            )
        assertEquals(8, trace.start())
        trace.recordPostDispatchPressed(
            input = requireNotNull(staleInput),
            sampledAtUptimeMillis = 2,
            pressed = true,
        )
        val downSequence =
            trace.recordTouch(
                eventTimeMillis = 100,
                downTimeMillis = 90,
                action = TouchTraceAction.DOWN.maskedValue,
                pressedBefore = false,
                enabled = true,
                focused = true,
                inside = true,
                shown = true,
            )
        assertEquals(1L, downSequence?.sequence)
        trace.recordPostDispatchPressed(
            input = requireNotNull(downSequence),
            sampledAtUptimeMillis = 120,
            pressed = true,
        )
        val upSequence =
            trace.recordTouch(
                eventTimeMillis = 150,
                downTimeMillis = 90,
                action = TouchTraceAction.UP.maskedValue,
                pressedBefore = true,
                enabled = true,
                focused = true,
                inside = true,
                shown = true,
            )
        trace.recordPostDispatchPressed(
            input = requireNotNull(upSequence),
            sampledAtUptimeMillis = 170,
            pressed = false,
        )
        trace.recordClick(storedCounter = 1, saveSucceeded = true)

        val drain = trace.stopAndDrain()

        assertFalse(trace.isCapturing)
        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), drain.records.map(TouchTraceRecord::sequence))
        assertEquals(0L, drain.droppedRecordCount)
        val down = drain.records[0] as TouchTraceRecord.Touch
        assertEquals(100L, down.eventTimeMillis)
        assertEquals(90L, down.downTimeMillis)
        assertEquals(TouchTraceAction.DOWN, down.action)
        assertFalse(down.pressedBefore)
        assertTrue(down.enabled)
        assertTrue(down.focused)
        assertTrue(down.inside)
        assertTrue(down.shown)
        val downSample = drain.records[1] as TouchTraceRecord.PressedSample
        assertEquals(down.sequence, downSample.inputSequence)
        assertEquals(120L, downSample.sampledAtUptimeMillis)
        assertTrue(downSample.pressed)
        val upSample = drain.records[3] as TouchTraceRecord.PressedSample
        assertEquals(3L, upSample.inputSequence)
        assertEquals(170L, upSample.sampledAtUptimeMillis)
        assertFalse(upSample.pressed)
        assertEquals(
            "kind=pressed-sample phase=post-dispatch-next-frame sequence=2 inputSequence=1 " +
                "sampledAtUptimeMs=120 pressed=true",
            downSample.toLogcatLine(),
        )
        assertEquals(
            "kind=touch sequence=1 eventTimeMs=100 downTimeMs=90 action=DOWN " +
                "pressedBefore=false enabled=true focused=true inside=true shown=true",
            down.toLogcatLine(),
        )

        assertNull(
            trace.recordTouch(
                200,
                200,
                TouchTraceAction.UP.maskedValue,
                true,
                true,
                true,
                true,
                true,
            )
        )
        assertTrue(trace.stopAndDrain().records.isEmpty())

        trace.start()
        assertEquals(
            1L,
            trace
                .recordTouch(
                    300,
                    300,
                    TouchTraceAction.CANCEL.maskedValue,
                    true,
                    true,
                    true,
                    false,
                    true,
                )
                ?.sequence,
        )
        assertEquals(1L, trace.stopAndDrain().records.first().sequence)
    }

    @Test
    fun ringIsBoundedAndReportsOverwrittenRecords() {
        val trace = TouchTrace(capacity = 2)
        trace.start()

        val downSequence =
            trace.recordTouch(
                10,
                10,
                TouchTraceAction.DOWN.maskedValue,
                false,
                true,
                true,
                true,
                true,
            )
        trace.recordTouch(20, 10, TouchTraceAction.UP.maskedValue, true, true, true, true, true)
        trace.recordClick(storedCounter = 1, saveSucceeded = true)

        val drain = trace.stopAndDrain()

        assertEquals(1L, drain.droppedRecordCount)
        assertEquals(2, drain.records.size)
        assertEquals(listOf(2L, 3L), drain.records.map(TouchTraceRecord::sequence))
        assertEquals(1L, downSequence?.sequence)
        val secondDrain = trace.stopAndDrain()
        assertTrue(secondDrain.records.isEmpty())
        assertEquals(0L, secondDrain.droppedRecordCount)
    }

    @Test
    fun clicksAreCorrelatedOnlyWhenOneIdentifiableUpIsPending() {
        val trace = TouchTrace(capacity = 16)
        trace.start()

        trace.recordClick(storedCounter = null, saveSucceeded = false)
        recordUp(trace, eventTime = 10)
        trace.recordClick(storedCounter = 1, saveSucceeded = true)
        recordUp(trace, eventTime = 20)
        recordUp(trace, eventTime = 30)
        trace.recordClick(storedCounter = 2, saveSucceeded = true)
        trace.recordClick(storedCounter = 3, saveSucceeded = true)
        recordUp(trace, eventTime = 40)
        trace.recordClick(storedCounter = 4, saveSucceeded = true)

        val clicks = trace.stopAndDrain().records.filterIsInstance<TouchTraceRecord.Click>()

        assertEquals(listOf(1L, 2L, 3L, 4L, 5L), clicks.map(TouchTraceRecord.Click::clickOrdinal))
        assertEquals(
            listOf(
                TouchTraceRecord.Click.Correlation.AMBIGUOUS,
                TouchTraceRecord.Click.Correlation.UNIQUE_UP,
                TouchTraceRecord.Click.Correlation.AMBIGUOUS,
                TouchTraceRecord.Click.Correlation.AMBIGUOUS,
                TouchTraceRecord.Click.Correlation.UNIQUE_UP,
            ),
            clicks.map(TouchTraceRecord.Click::correlation),
        )
        assertEquals(0L, clicks[0].pendingUpCount)
        assertNull(clicks[0].correlatedUpSequence)
        assertEquals(1, clicks[1].storedCounter)
        assertEquals(2L, clicks[1].correlatedUpSequence)
        assertEquals(2L, clicks[2].pendingUpCount)
        assertNull(clicks[2].correlatedUpSequence)
        assertEquals(1L, clicks[3].pendingUpCount)
        assertNull(clicks[3].correlatedUpSequence)
        assertTrue(clicks[4].saveSucceeded)
        assertEquals(8L, clicks[4].correlatedUpSequence)
        assertTrue(clicks[4].toLogcatLine().contains("correlation=unique_up"))
    }

    private fun recordUp(trace: TouchTrace, eventTime: Long) {
        trace.recordTouch(
            eventTimeMillis = eventTime,
            downTimeMillis = eventTime - 1,
            action = TouchTraceAction.UP.maskedValue,
            pressedBefore = true,
            enabled = true,
            focused = true,
            inside = true,
            shown = true,
        )
    }
}
