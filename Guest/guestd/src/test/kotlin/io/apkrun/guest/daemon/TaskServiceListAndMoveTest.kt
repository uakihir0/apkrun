package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.TaskInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskServiceListAndMoveTest {
    @Test
    fun listTasksFiltersByDisplayAndKeepsSystemOrder() {
        val service =
            service(
                mutableListOf(
                    task(4, 2),
                    task(5, 0),
                    task(6, 2),
                )
            )

        assertEquals(listOf(4, 6), service.list(2).map { it.taskId })
        assertEquals(listOf(4, 5, 6), service.list().map { it.taskId })
    }

    @Test
    fun listTasksRejectsNegativeDisplayIds() {
        val failure = assertThrows(GuestFailure::class.java) { service(mutableListOf()).list(-1) }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, failure.code)
    }

    @Test
    fun moveToDisplayUsesAndroidMoveAndRestoresThePriorForegroundTaskWhenToBackIsSet() {
        val tasks = mutableListOf(task(9, 1), task(4, 0, visible = true))
        val moves = mutableListOf<Pair<Int, Int>>()
        val focused = mutableListOf<Int>()
        val service =
            service(
                tasks,
                moveTask = { taskId, displayId ->
                    moves += taskId to displayId
                    tasks.replaceAll { task ->
                        if (task.taskId == taskId) task.toBuilder().setDisplayId(displayId).build()
                        else task
                    }
                },
                focusTask = focused::add,
            )

        service.moveToDisplay(taskId = 9, displayId = 0, toBack = true)

        assertEquals(listOf(9 to 0), moves)
        assertEquals(listOf(4), focused)
        assertEquals(0, tasks.first().displayId)
    }

    @Test
    fun aMissingTaskIsNotMoved() {
        val moves = mutableListOf<Pair<Int, Int>>()
        val failure =
            assertThrows(GuestFailure::class.java) {
                service(mutableListOf(), moveTask = { id, display -> moves += id to display })
                    .moveToDisplay(99, 0, false)
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, failure.code)
        assertTrue(moves.isEmpty())
    }

    @Test
    fun moveToBackFailsBeforeMovingWhenNoVisibleTaskCanRemainInFront() {
        val tasks = mutableListOf(task(9, 1))
        val moves = mutableListOf<Pair<Int, Int>>()
        val failure =
            assertThrows(GuestFailure::class.java) {
                service(
                        tasks,
                        moveTask = { id, display -> moves += id to display },
                    )
                    .moveToDisplay(9, 0, true)
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION, failure.code)
        assertTrue(moves.isEmpty())
    }

    private fun service(
        tasks: MutableList<TaskInfo>,
        moveTask: (Int, Int) -> Unit = { taskId, displayId ->
            tasks.replaceAll { task ->
                if (task.taskId == taskId) task.toBuilder().setDisplayId(displayId).build()
                else task
            }
        },
        focusTask: (Int) -> Unit = {},
    ) =
        TaskService(
            events = EventBus(),
            callbacks = {},
            readTaskList = { tasks.toList() },
            moveTaskById = moveTask,
            focusTaskById = focusTask,
        )

    private fun task(taskId: Int, displayId: Int, visible: Boolean = false): TaskInfo =
        TaskInfo.newBuilder()
            .setTaskId(taskId)
            .setDisplayId(displayId)
            .setPackage("io.apkrun.fixture.hellotext")
            .setVisible(visible)
            .build()
}
