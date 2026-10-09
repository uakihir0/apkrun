package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.CancelAll
import io.apkrun.guest.protocol.v1.InputBatch
import io.apkrun.guest.protocol.v1.InputEvent
import io.apkrun.guest.protocol.v1.KeyAction
import io.apkrun.guest.protocol.v1.KeyEvent
import io.apkrun.guest.protocol.v1.TouchEvent
import io.apkrun.guest.protocol.v1.TouchPhase
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InputValidatorTest {
    private val bounds = DisplayBounds(1080, 2400)

    private fun touch(
        x: Float,
        y: Float,
        pointer: Int = 0,
        phase: TouchPhase = TouchPhase.TOUCH_PHASE_DOWN,
    ) =
        InputEvent.newBuilder()
            .setTouch(TouchEvent.newBuilder().setPhase(phase).setPointerId(pointer).setX(x).setY(y))
            .build()

    @Test
    fun aTouchInsideTheDisplayIsValid() {
        assertTrue(InputValidator.isValid(touch(10f, 20f), bounds))
    }

    @Test
    fun aTouchAtTheEdgeOrOutsideIsNotValid() {
        assertFalse(InputValidator.isValid(touch(1080f, 20f), bounds))
        assertFalse(InputValidator.isValid(touch(-1f, 20f), bounds))
        assertFalse(InputValidator.isValid(touch(10f, 2400f), bounds))
    }

    @Test
    fun aNonFiniteCoordinateIsNotValid() {
        assertFalse(InputValidator.isValid(touch(Float.NaN, 20f), bounds))
        assertFalse(InputValidator.isValid(touch(10f, Float.POSITIVE_INFINITY), bounds))
    }

    @Test
    fun aPointerOutsideTheMultiTouchRangeIsNotValid() {
        assertFalse(InputValidator.isValid(touch(10f, 20f, pointer = 10), bounds))
        assertFalse(InputValidator.isValid(touch(10f, 20f, pointer = -1), bounds))
    }

    @Test
    fun aTouchWithoutAPhaseIsNotValid() {
        assertFalse(
            InputValidator.isValid(
                touch(10f, 20f, phase = TouchPhase.TOUCH_PHASE_UNSPECIFIED),
                bounds,
            )
        )
    }

    @Test
    fun aKeyNeedsAnActionAndAPositiveCode() {
        val valid =
            InputEvent.newBuilder()
                .setKey(KeyEvent.newBuilder().setAction(KeyAction.KEY_ACTION_DOWN).setKeyCode(66))
                .build()
        val noCode =
            InputEvent.newBuilder()
                .setKey(KeyEvent.newBuilder().setAction(KeyAction.KEY_ACTION_DOWN))
                .build()
        val noAction = InputEvent.newBuilder().setKey(KeyEvent.newBuilder().setKeyCode(66)).build()
        assertTrue(InputValidator.isValid(valid, bounds))
        assertFalse(InputValidator.isValid(noCode, bounds))
        assertFalse(InputValidator.isValid(noAction, bounds))
    }

    @Test
    fun cancelAllIsAlwaysValidAndAnEmptyEventIsNot() {
        assertTrue(
            InputValidator.isValid(
                InputEvent.newBuilder().setCancelAll(CancelAll.getDefaultInstance()).build(),
                bounds,
            )
        )
        assertFalse(InputValidator.isValid(InputEvent.getDefaultInstance(), bounds))
    }
}

class InputServiceTest {
    private val service = InputService { id -> if (id == 0) DisplayBounds(100, 100) else null }

    private fun batch(displayId: Int, ack: Boolean, events: List<InputEvent>): InputBatch =
        InputBatch.newBuilder()
            .setBatchSeq(5)
            .setDisplayId(displayId)
            .setAckRequested(ack)
            .addAllEvents(events)
            .build()

    @Test
    fun aBatchWithAnAckGetsItsRejectedCount() {
        val events =
            listOf(
                InputEvent.newBuilder().setCancelAll(CancelAll.getDefaultInstance()).build(),
                InputEvent.newBuilder()
                    .setTouch(TouchEvent.newBuilder().setX(500f).setY(1f))
                    .build(),
            )
        val ack = service.submit(batch(0, ack = true, events = events))
        assertEquals(5L, ack!!.getBatchSeq())
        assertEquals(1, ack.getRejectedEvents())
        assertEquals(0, ack.getReceiveToInjectMicros())
    }

    @Test
    fun aBatchWithoutAnAckGetsNoAck() {
        assertNull(service.submit(batch(0, ack = false, events = emptyList())))
    }

    @Test
    fun aBatchForAnUnknownDisplayDropsEveryEvent() {
        val events =
            listOf(InputEvent.newBuilder().setCancelAll(CancelAll.getDefaultInstance()).build())
        val ack = service.submit(batch(3, ack = true, events = events))
        assertEquals(1, ack!!.getRejectedEvents())
    }

    @Test
    fun abatchOverTheLimitDropsEveryEvent() {
        val events =
            List(InputValidator.MAXIMUM_EVENTS_PER_BATCH + 1) {
                InputEvent.newBuilder().setCancelAll(CancelAll.getDefaultInstance()).build()
            }
        val ack = service.submit(batch(0, ack = true, events = events))
        assertEquals(InputValidator.MAXIMUM_EVENTS_PER_BATCH + 1, ack!!.getRejectedEvents())
        assertEquals(1L, service.counters().getBatches())
        assertEquals(
            InputValidator.MAXIMUM_EVENTS_PER_BATCH + 1L,
            service.counters().getEventsRejected(),
        )
    }
}
