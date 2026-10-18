package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.TaskInfo
import io.apkrun.guest.protocol.v1.TaskVanished
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TaskServiceStopApplicationTest {
    @Test
    fun stoppingAPackageWithNoTasksIsAnIdempotentSuccess() = runBlocking {
        val fixture = fixture(emptyList())

        fixture.service.removeAllForPackage(TARGET_PACKAGE)

        assertTrue(fixture.removedTaskIds.isEmpty())
        assertTrue(fixture.remainingTasks.isEmpty())
        assertTrue(fixture.taskVanishedEvents().isEmpty())
    }

    @Test
    fun finishTasksRemovesEveryTaskAndPublishesTaskVanishedBeforeReturning() = runBlocking {
        val fixture =
            fixture(
                listOf(
                    task(taskId = 7, displayId = 0, packageName = TARGET_PACKAGE),
                    task(taskId = 8, displayId = 1, packageName = TARGET_PACKAGE),
                    task(taskId = 9, displayId = 2, packageName = TARGET_PACKAGE),
                )
            )

        fixture.service.removeAllForPackage(TARGET_PACKAGE)

        assertEquals(listOf(7, 8, 9), fixture.removedTaskIds)
        assertTrue(fixture.remainingTasks.isEmpty())
        assertEquals(
            listOf(7, 8, 9),
            fixture.taskVanishedEvents().map { it.getTaskId() },
        )
    }

    @Test
    fun finishTasksLeavesOtherPackagesAndTheirEventsAlone() = runBlocking {
        val fixture =
            fixture(
                listOf(
                    task(taskId = 7, displayId = 0, packageName = TARGET_PACKAGE),
                    task(taskId = 8, displayId = 0, packageName = OTHER_PACKAGE),
                    task(taskId = 9, displayId = 1, packageName = TARGET_PACKAGE),
                )
            )

        fixture.service.removeAllForPackage(TARGET_PACKAGE)

        assertEquals(listOf(7, 9), fixture.removedTaskIds)
        assertEquals(listOf(8), fixture.remainingTasks.map { it.getTaskId() })
        val vanished = fixture.taskVanishedEvents()
        assertEquals(listOf(7, 9), vanished.map { it.getTaskId() })
        assertTrue(vanished.none { it.getPackage() == OTHER_PACKAGE })
    }

    @Test
    fun cancellationInterruptsTheWaitAndReleasesTheRemovalLock() = runBlocking {
        val enteredWait = CompletableDeferred<Unit>()
        val fixture =
            fixture(
                initialTasks =
                    listOf(task(taskId = 7, displayId = 0, packageName = TARGET_PACKAGE)),
                removeTaskById = {},
                waitMillis = {
                    enteredWait.complete(Unit)
                    awaitCancellation()
                },
            )
        val stopping = async { fixture.service.removeAllForPackage(TARGET_PACKAGE) }

        enteredWait.await()
        stopping.cancelAndJoin()

        assertTrue(stopping.isCancelled)
        fixture.remainingTasks.clear()
        fixture.service.removeAllForPackage(TARGET_PACKAGE)
        assertTrue(fixture.remainingTasks.isEmpty())
    }

    @Test
    fun tasksThatRemainAfterTheDeadlineReturnTimeout() = runBlocking {
        var now = 0L
        val fixture =
            fixture(
                initialTasks =
                    listOf(task(taskId = 7, displayId = 0, packageName = TARGET_PACKAGE)),
                removeTaskById = {},
                nowMillis = { now },
                waitMillis = { now += it },
            )
        var failure: GuestFailure? = null

        try {
            fixture.service.removeAllForPackage(TARGET_PACKAGE)
        } catch (error: GuestFailure) {
            failure = error
        }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT, failure?.code)
        assertFalse(fixture.remainingTasks.isEmpty())
    }

    private fun fixture(
        initialTasks: List<TaskInfo>,
        nowMillis: () -> Long = { System.nanoTime() / 1_000_000L },
        waitMillis: suspend (Long) -> Unit = { kotlinx.coroutines.delay(it) },
        removeTaskById: ((Int) -> Unit)? = null,
    ): Fixture {
        val remainingTasks = initialTasks.toMutableList()
        val removedTaskIds = mutableListOf<Int>()
        val events = EventBus()
        val output = ByteArrayOutputStream()
        val service =
            TaskService(
                events = events,
                callbacks = {},
                readTaskList = { remainingTasks.toList() },
                removeTaskById =
                    removeTaskById
                        ?: { taskId ->
                            removedTaskIds += taskId
                            remainingTasks.removeAll { it.getTaskId() == taskId }
                            Unit
                        },
                nowMillis = nowMillis,
                waitMillis = waitMillis,
            )
        service.refresh()
        events.attach(FrameWriter(output))
        return Fixture(service, remainingTasks, removedTaskIds, output)
    }

    private fun task(taskId: Int, displayId: Int, packageName: String): TaskInfo =
        TaskInfo.newBuilder()
            .setTaskId(taskId)
            .setDisplayId(displayId)
            .setPackage(packageName)
            .build()

    private class Fixture(
        val service: TaskService,
        val remainingTasks: MutableList<TaskInfo>,
        val removedTaskIds: MutableList<Int>,
        private val output: ByteArrayOutputStream,
    ) {
        fun taskVanishedEvents(): List<TaskVanished> {
            val reader = FrameReader(ByteArrayInputStream(output.toByteArray()))
            val vanished = mutableListOf<TaskVanished>()
            while (true) {
                val event =
                    try {
                        reader.next().event
                    } catch (_: EOFException) {
                        return vanished
                    }
                if (event.kindCase == Event.KindCase.TASK_VANISHED) {
                    vanished += event.taskVanished
                }
            }
        }
    }

    private companion object {
        const val TARGET_PACKAGE = "io.apkrun.fixture.hellotext"
        const val OTHER_PACKAGE = "io.apkrun.fixture.hellocompose"
    }
}
