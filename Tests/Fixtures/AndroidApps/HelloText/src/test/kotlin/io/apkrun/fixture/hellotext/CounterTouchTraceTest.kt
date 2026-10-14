package io.apkrun.fixture.hellotext

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CounterTouchTraceTest {
    @Test
    fun bufferKeepsNewestEventsInOrderAndCountsEvictions() {
        val trace = CounterTouchTraceBuffer(capacity = 3)
        trace.start(atNanos = 100)
        trace.recordTouch(atNanos = 110, action = TouchTraceAction.DOWN, pressed = false)
        trace.recordPressed(atNanos = 120, pressed = true)
        trace.recordTouch(atNanos = 130, action = TouchTraceAction.UP, pressed = true)
        trace.recordClickCallback(atNanos = 140)

        val json = document(trace.drainLines())

        assertTrue(json.contains("\"dropped_events\":1"))
        assertFalse(json.contains("\"seq\":1"))
        assertTrue(json.indexOf("\"seq\":2") < json.indexOf("\"seq\":3"))
        assertTrue(json.indexOf("\"seq\":3") < json.indexOf("\"seq\":4"))
        assertTrue(json.contains("\"elapsed_ns\":20"))
        assertTrue(json.contains("\"kind\":\"click_callback\""))
    }

    @Test
    fun traceCommandsStartExplicitlyAndReadConsumesTheCapture() {
        val trace = CounterTouchTraceBuffer(capacity = 8)
        val commands = DebugCounterTouchTraceCommands(trace)

        trace.recordClickCallback(atNanos = 5)
        assertFalse(trace.isRecording())
        assertEquals(
            listOf("debug trace started"),
            commands.run(
                DebugCounterTouchTraceCommands.ACTION_TRACE_START,
                atNanos = 10,
                mode = CounterClickExecutionMode.SYNCHRONOUS.wireValue,
            ),
        )
        trace.recordTouch(atNanos = 20, action = TouchTraceAction.DOWN, pressed = false)
        trace.recordPressed(atNanos = 21, pressed = true)
        trace.recordTouch(atNanos = 25, action = TouchTraceAction.MOVE, pressed = true)
        trace.recordTouch(atNanos = 30, action = TouchTraceAction.UP, pressed = true)
        trace.recordClickCallback(atNanos = 32)
        trace.recordPressed(atNanos = 33, pressed = false)
        trace.recordCounterWrite(
            atNanos = 50,
            durationNanos = 7,
            requestedValue = 1,
            saved = true,
            observedValue = 1,
        )
        trace.recordPressedStateWaitElapsed(atNanos = 55)

        val firstRead = commands.run(DebugCounterTouchTraceCommands.ACTION_TRACE_READ, atNanos = 60)
        assertFalse(trace.isRecording())
        val firstDocument = document(firstRead!!)
        assertTrue(firstDocument.contains("\"started_at_ns\":10"))
        assertTrue(firstDocument.contains("\"mode\":\"synchronous\""))
        assertTrue(
            firstDocument.contains("\"kind\":\"touch\",\"action\":\"down\",\"pressed\":false")
        )
        assertTrue(
            firstDocument.contains("\"kind\":\"touch\",\"action\":\"move\",\"pressed\":true")
        )
        assertTrue(firstDocument.contains("\"kind\":\"pressed\",\"pressed\":true"))
        assertTrue(firstDocument.contains("\"kind\":\"click_callback\""))
        assertTrue(firstDocument.contains("\"kind\":\"pressed_state_wait_elapsed\""))
        assertTrue(
            firstDocument.contains(
                "\"kind\":\"counter_write\",\"duration_ns\":7,\"requested\":1,\"saved\":true,\"observed\":1"
            )
        )
        val upIndex = firstDocument.indexOf("\"action\":\"up\"")
        val moveIndex = firstDocument.indexOf("\"action\":\"move\"")
        val callbackIndex = firstDocument.indexOf("\"kind\":\"click_callback\"")
        val writeIndex = firstDocument.indexOf("\"kind\":\"counter_write\"")
        assertTrue(upIndex >= 0)
        assertTrue(moveIndex >= 0)
        assertTrue(callbackIndex >= 0)
        assertTrue(moveIndex < upIndex)
        assertTrue(writeIndex >= 0)
        assertTrue(upIndex < callbackIndex)
        assertTrue(callbackIndex < writeIndex)
        assertTrue(writeIndex < firstDocument.indexOf("\"kind\":\"pressed_state_wait_elapsed\""))

        trace.recordClickCallback(atNanos = 70)
        val secondDocument =
            document(commands.run(DebugCounterTouchTraceCommands.ACTION_TRACE_READ, atNanos = 80)!!)
        assertTrue(secondDocument.contains("\"started_at_ns\":null"))
        assertTrue(secondDocument.contains("\"events\":[]"))
        assertFalse(secondDocument.contains("click_callback"))
    }

    @Test
    fun repeatedStartIsRejectedWithoutReplacingTheActiveCapture() {
        val trace = CounterTouchTraceBuffer(capacity = 8)
        val commands = DebugCounterTouchTraceCommands(trace)

        assertEquals(
            listOf("debug trace started"),
            commands.run(
                DebugCounterTouchTraceCommands.ACTION_TRACE_START,
                atNanos = 10,
                mode = "queue",
            ),
        )
        trace.recordClickCallback(atNanos = 20)

        assertEquals(
            listOf("debug trace start rejected: a capture is already active"),
            commands.run(
                DebugCounterTouchTraceCommands.ACTION_TRACE_START,
                atNanos = 30,
                mode = CounterClickExecutionMode.SYNCHRONOUS.wireValue,
            ),
        )
        assertEquals(CounterClickExecutionMode.QUEUE, trace.currentExecutionMode())

        val json =
            document(commands.run(DebugCounterTouchTraceCommands.ACTION_TRACE_READ, atNanos = 40)!!)
        assertTrue(json.contains("\"started_at_ns\":10"))
        assertTrue(json.contains("\"mode\":\"queue\""))
        assertTrue(json.contains("\"kind\":\"click_callback\""))
    }

    @Test
    fun traceReadSplitsLargeJsonIntoBoundedOrderedLogLines() {
        val trace = CounterTouchTraceBuffer(capacity = 96)
        trace.start(atNanos = 0)
        repeat(96) { index ->
            trace.recordTouch(
                atNanos = index.toLong() + 1,
                action = if (index % 2 == 0) TouchTraceAction.DOWN else TouchTraceAction.UP,
                pressed = index % 2 == 1,
            )
        }

        val lines = trace.drainLines()

        assertTrue(lines.size > 1)
        assertTrue(lines.all { it.length <= CounterTouchTraceBuffer.MAX_JSON_CHUNK_CHARS + 40 })
        assertEquals(
            lines.size,
            lines.indices.count { index ->
                lines[index].startsWith("debug trace chunk ${index + 1}/${lines.size} ")
            },
        )
        val json = document(lines)
        assertTrue(json.startsWith("{\"version\":1,"))
        assertTrue(json.endsWith("]}"))
        assertTrue(json.contains("\"seq\":96"))
    }

    @Test
    fun hundredClickCaptureFitsTheBoundedBufferAndReassemblesFromEveryChunk() {
        val trace = CounterTouchTraceBuffer()
        trace.start(atNanos = 0, mode = CounterClickExecutionMode.QUEUE)
        var atNanos = 1L
        repeat(100) { click ->
            trace.recordTouch(atNanos++, TouchTraceAction.DOWN, pressed = false)
            trace.recordPressed(atNanos++, pressed = true)
            trace.recordTouch(atNanos++, TouchTraceAction.UP, pressed = true)
            trace.recordClickCallback(atNanos++)
            trace.recordPressed(atNanos++, pressed = false)
            trace.recordCounterWrite(
                atNanos = atNanos++,
                durationNanos = 1_000,
                requestedValue = click + 1,
                saved = true,
                observedValue = click + 1,
            )
        }

        val lines = trace.drainLines()
        val json = document(lines)

        assertTrue(json.contains("\"dropped_events\":0"))
        assertEquals(600, "\"seq\":".toRegex().findAll(json).count())
        assertTrue("100 clicks should remain bounded for the logcat transport", lines.size < 50)
        assertTrue(lines.all { it.length <= CounterTouchTraceBuffer.MAX_JSON_CHUNK_CHARS + 40 })
        assertEquals(
            lines.size,
            lines.indices.count { index ->
                lines[index].startsWith("debug trace chunk ${index + 1}/${lines.size} ")
            },
        )
        assertTrue(json.startsWith("{\"version\":1,"))
        assertTrue(json.endsWith("]}"))
        val sequences =
            "\"seq\":([0-9]+)"
                .toRegex()
                .findAll(json)
                .map { match -> match.groupValues[1].toInt() }
                .toList()
        assertEquals((1..600).toList(), sequences)
    }

    @Test
    fun traceReadSubmittedAfterPendingCounterWorkIncludesItsCommitRecord() {
        val worker = Executors.newSingleThreadExecutor()
        val queue = CounterOperationQueue(worker)
        val commitStarted = CountDownLatch(1)
        val allowCommitToFinish = CountDownLatch(1)
        val trace = CounterTouchTraceBuffer(capacity = 8)
        val commands = DebugCounterTouchTraceCommands(trace)
        trace.start(atNanos = 10, mode = CounterClickExecutionMode.QUEUE)
        trace.recordClickCallback(atNanos = 20)

        try {
            queue.submit {
                commitStarted.countDown()
                check(allowCommitToFinish.await(5, TimeUnit.SECONDS))
                trace.recordCounterWrite(
                    atNanos = 30,
                    durationNanos = 7,
                    requestedValue = 1,
                    saved = true,
                    observedValue = 1,
                )
            }
            assertTrue(commitStarted.await(5, TimeUnit.SECONDS))

            val read = queue.submit {
                commands.run(DebugCounterTouchTraceCommands.ACTION_TRACE_READ, atNanos = 40)!!
            }
            assertFalse("the read must wait behind the earlier queued commit", read.isDone)
            allowCommitToFinish.countDown()

            val json = document(read.get(5, TimeUnit.SECONDS))
            val callbackIndex = json.indexOf("\"kind\":\"click_callback\"")
            val writeIndex = json.indexOf("\"kind\":\"counter_write\"")
            assertTrue(callbackIndex >= 0)
            assertTrue(writeIndex >= 0)
            assertTrue(callbackIndex < writeIndex)
        } finally {
            allowCommitToFinish.countDown()
            worker.shutdownNow()
        }
    }

    @Test
    fun traceStartSubmittedAfterPendingCounterWorkExcludesTheEarlierCommit() {
        val worker = Executors.newSingleThreadExecutor()
        val queue = CounterOperationQueue(worker)
        val commitStarted = CountDownLatch(1)
        val allowCommitToFinish = CountDownLatch(1)
        val trace = CounterTouchTraceBuffer(capacity = 8)
        val commands = DebugCounterTouchTraceCommands(trace)

        try {
            queue.submit {
                commitStarted.countDown()
                check(allowCommitToFinish.await(5, TimeUnit.SECONDS))
                trace.recordCounterWrite(
                    atNanos = 30,
                    durationNanos = 7,
                    requestedValue = 1,
                    saved = true,
                    observedValue = 1,
                )
            }
            assertTrue(commitStarted.await(5, TimeUnit.SECONDS))

            val start = queue.submit {
                commands.run(
                    DebugCounterTouchTraceCommands.ACTION_TRACE_START,
                    atNanos = 40,
                    mode = CounterClickExecutionMode.SYNCHRONOUS.wireValue,
                )!!
            }
            assertFalse("the start must wait behind the earlier queued commit", start.isDone)
            allowCommitToFinish.countDown()
            assertEquals(listOf("debug trace started"), start.get(5, TimeUnit.SECONDS))

            trace.recordClickCallback(atNanos = 50)
            val read = queue.submit {
                commands.run(DebugCounterTouchTraceCommands.ACTION_TRACE_READ, atNanos = 60)!!
            }
            val json = document(read.get(5, TimeUnit.SECONDS))
            assertTrue(json.contains("\"started_at_ns\":40"))
            assertTrue(json.contains("\"kind\":\"click_callback\""))
            assertFalse(json.contains("\"kind\":\"counter_write\""))
        } finally {
            allowCommitToFinish.countDown()
            worker.shutdownNow()
        }
    }

    @Test
    fun unknownTraceCommandIsIgnored() {
        val commands = DebugCounterTouchTraceCommands(CounterTouchTraceBuffer())

        assertNull(commands.run("io.apkrun.fixture.hellotext.debug.UNKNOWN", atNanos = 0))
        assertNull(commands.run(null, atNanos = 0))
    }

    @Test
    fun invalidTraceModeDoesNotStartARecording() {
        val trace = CounterTouchTraceBuffer()
        val commands = DebugCounterTouchTraceCommands(trace)

        assertEquals(
            listOf("debug trace start rejected: mode must be queue or synchronous"),
            commands.run(
                DebugCounterTouchTraceCommands.ACTION_TRACE_START,
                atNanos = 10,
                mode = "parallel",
            ),
        )
        assertFalse(trace.isRecording())
    }

    private fun document(lines: List<String>): String =
        lines.joinToString(separator = "") { line ->
            line.substringAfter(TRACE_LINE_PREFIX).substringAfter(' ')
        }

    private companion object {
        const val TRACE_LINE_PREFIX = "debug trace chunk "
    }
}
