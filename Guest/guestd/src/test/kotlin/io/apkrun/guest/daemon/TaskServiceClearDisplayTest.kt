package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.ClearPolicy
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.TaskInfo
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskServiceClearDisplayTest {
    @Test
    fun finishTasksClearsOnlyTheRequestedDisplayAndPublishesCompletionAfterTaskEvents() =
        runBlocking {
            val fixture =
                fixture(
                    listOf(
                        task(taskId = 7, displayId = 1),
                        task(taskId = 8, displayId = 1),
                        task(taskId = 9, displayId = 2),
                    )
                )

            fixture.service.clearDisplay(clearDisplay(1, ClearPolicy.CLEAR_POLICY_FINISH_TASKS))

            assertEquals(listOf(7, 8), fixture.removedTaskIds)
            assertEquals(listOf(9), fixture.remainingTasks.map { it.getTaskId() })
            val events = fixture.events()
            val taskVanished = events.filter { it.kindCase == Event.KindCase.TASK_VANISHED }
            assertEquals(listOf(7, 8), taskVanished.map { it.taskVanished.taskId })
            assertTrue(events.none { it.kindCase == Event.KindCase.DISPLAY_EMPTY })
            val tasksCleared = events.single { it.kindCase == Event.KindCase.TASKS_CLEARED }
            assertEquals(1, tasksCleared.tasksCleared.displayId)
            assertEquals(0, tasksCleared.tasksCleared.remainingTasks)
            assertTrue(events.indexOf(tasksCleared) > events.indexOf(taskVanished.last()))
        }

    @Test
    fun moveToDefaultDisplayMovesEveryTaskAndPublishesCompletion() = runBlocking {
        val fixture = fixture(listOf(task(taskId = 7, displayId = 1)))

        fixture.service.clearDisplay(
            clearDisplay(1, ClearPolicy.CLEAR_POLICY_MOVE_TO_DEFAULT_DISPLAY)
        )

        assertTrue(fixture.removedTaskIds.isEmpty())
        assertEquals(0, fixture.remainingTasks.single().displayId)
        val events = fixture.events()
        assertEquals(1, events.count { it.kindCase == Event.KindCase.TASK_CHANGED })
        assertEquals(1, events.count { it.kindCase == Event.KindCase.TASKS_CLEARED })
        assertTrue(events.none { it.kindCase == Event.KindCase.DISPLAY_EMPTY })
    }

    @Test
    fun tasksThatRemainPastTheDeadlineReturnTimeoutWithoutCompletionEvent() = runBlocking {
        var now = 0L
        val fixture =
            fixture(
                listOf(task(taskId = 7, displayId = 1)),
                removeTask = {},
                nowMillis = { now },
                waitMillis = { now += it },
            )
        var failure: GuestFailure? = null

        try {
            fixture.service.clearDisplay(clearDisplay(1, ClearPolicy.CLEAR_POLICY_FINISH_TASKS))
        } catch (error: GuestFailure) {
            failure = error
        }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT, failure?.code)
        assertEquals("1", failure?.detail?.get("remaining_tasks"))
        assertFalse(fixture.remainingTasks.isEmpty())
        assertTrue(fixture.events().none { it.kindCase == Event.KindCase.TASKS_CLEARED })
        assertTrue(fixture.events().none { it.kindCase == Event.KindCase.DISPLAY_EMPTY })
    }

    private fun fixture(
        initialTasks: List<TaskInfo>,
        removeTask: ((Int) -> Unit)? = null,
        nowMillis: () -> Long = { System.nanoTime() / 1_000_000L },
        waitMillis: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) },
    ): Fixture {
        val remainingTasks = initialTasks.toMutableList()
        val removedTaskIds = mutableListOf<Int>()
        val eventBus = EventBus()
        val output = ByteArrayOutputStream()
        val service =
            TaskService(
                events = eventBus,
                callbacks = {},
                readTaskList = { remainingTasks.toList() },
                removeTaskById =
                    removeTask
                        ?: { taskId ->
                            removedTaskIds += taskId
                            remainingTasks.removeAll { it.getTaskId() == taskId }
                            Unit
                        },
                moveTaskById = { taskId, displayId ->
                    remainingTasks.replaceAll { task ->
                        if (task.getTaskId() == taskId) {
                            task.toBuilder().setDisplayId(displayId).build()
                        } else {
                            task
                        }
                    }
                },
                nowMillis = nowMillis,
                waitMillis = waitMillis,
            )
        service.refresh()
        eventBus.attach(FrameWriter(output))
        return Fixture(service, remainingTasks, removedTaskIds, output)
    }

    private fun clearDisplay(displayId: Int, policy: ClearPolicy): ClearDisplay =
        ClearDisplay.newBuilder().setDisplayId(displayId).setPolicy(policy).build()

    private fun task(taskId: Int, displayId: Int): TaskInfo =
        TaskInfo.newBuilder()
            .setTaskId(taskId)
            .setDisplayId(displayId)
            .setPackage("io.apkrun.fixture.hellotext")
            .build()

    private class Fixture(
        val service: TaskService,
        val remainingTasks: MutableList<TaskInfo>,
        val removedTaskIds: MutableList<Int>,
        private val output: ByteArrayOutputStream,
    ) {
        fun events(): List<Event> {
            val reader = FrameReader(ByteArrayInputStream(output.toByteArray()))
            val events = mutableListOf<Event>()
            while (true) {
                try {
                    events += reader.next().event
                } catch (_: EOFException) {
                    return events
                }
            }
        }
    }
}
