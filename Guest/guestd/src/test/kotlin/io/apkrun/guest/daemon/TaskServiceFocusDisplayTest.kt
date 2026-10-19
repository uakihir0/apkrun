package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.TaskInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskServiceFocusDisplayTest {
    @Test
    fun focusesTheMostRecentTaskOnTheRequestedDisplay() {
        val focusedTaskIds = mutableListOf<Int>()
        val service =
            taskService(
                tasks =
                    listOf(
                        task(taskId = 10, displayId = 0),
                        task(taskId = 20, displayId = 1),
                        task(taskId = 21, displayId = 1),
                        task(taskId = 11, displayId = 0),
                    ),
                focusTask = { focusedTaskIds += it },
            )

        service.focus(1)

        assertEquals(listOf(20), focusedTaskIds)
    }

    @Test
    fun aDisplayWithoutTasksReturnsNotFoundWithoutChangingFocus() {
        val focusedTaskIds = mutableListOf<Int>()
        val service =
            taskService(tasks = listOf(task(taskId = 10, displayId = 0))) {
                focusedTaskIds += it
            }
        var failure: GuestFailure? = null

        try {
            service.focus(1)
        } catch (error: GuestFailure) {
            failure = error
        }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, failure?.code)
        assertEquals("1", failure?.detail?.get("display_id"))
        assertTrue(focusedTaskIds.isEmpty())
    }

    @Test
    fun aNegativeDisplayIdReturnsInvalidArgumentWithoutReadingTasks() {
        var taskListRead = false
        val service =
            TaskService(
                events = EventBus(),
                callbacks = {},
                readTaskList = {
                    taskListRead = true
                    emptyList()
                },
                focusTaskById = {},
            )
        var failure: GuestFailure? = null

        try {
            service.focus(-1)
        } catch (error: GuestFailure) {
            failure = error
        }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, failure?.code)
        assertEquals("-1", failure?.detail?.get("display_id"))
        assertFalse(taskListRead)
    }

    private fun taskService(
        tasks: List<TaskInfo>,
        focusTask: (Int) -> Unit,
    ): TaskService =
        TaskService(
            events = EventBus(),
            callbacks = {},
            readTaskList = { tasks },
            focusTaskById = focusTask,
        )

    private fun task(taskId: Int, displayId: Int): TaskInfo =
        TaskInfo.newBuilder()
            .setTaskId(taskId)
            .setDisplayId(displayId)
            .setPackage("io.apkrun.fixture.hellotext")
            .build()
}
