package io.apkrun.guest.daemon

import android.content.Intent
import io.apkrun.guest.protocol.v1.DisplayInfo
import io.apkrun.guest.protocol.v1.DisplayMode
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchMode
import io.apkrun.guest.protocol.v1.StopApplication
import io.apkrun.guest.protocol.v1.StopMode
import io.apkrun.guest.protocol.v1.TaskInfo
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class LaunchServiceTest {
    @Test
    fun forceStopCallsActivityManagerAndWaitsUntilOnlyOtherPackagesRemain() = runBlocking {
        val remainingTasks =
            mutableListOf(
                task(taskId = 91, displayId = 0),
                task(taskId = 92, displayId = 1, packageName = OTHER_PACKAGE),
            )
        val forceStops = mutableListOf<Pair<String, Int>>()
        val service =
            service(
                displayInventory = emptyMap(),
                taskInventory = { remainingTasks.toList() },
                adapters =
                    LaunchServiceAdapters(
                        forceStopPackage = { packageName, userId ->
                            forceStops += packageName to userId
                            remainingTasks.removeAll { it.getPackage() == packageName }
                        }
                    ),
            )

        service.stop(
            StopApplication.newBuilder()
                .setPackage(TARGET_PACKAGE)
                .setMode(StopMode.STOP_MODE_FORCE_STOP)
                .build()
        )

        assertEquals(listOf(TARGET_PACKAGE to 0), forceStops)
        assertEquals(listOf(92), remainingTasks.map { it.getTaskId() })
    }

    @Test
    fun launchPassesRequestedDisplayOptionsToActivityManager() {
        var activityStarted = false
        var launchOptions: DisplayLaunchOptions? = null
        var activityArguments: Array<out Any?>? = null
        val options = Any()
        val task = task(taskId = 91, displayId = TARGET_DISPLAY)
        val service =
            service(
                displayInventory = mapOf(TARGET_DISPLAY to display(TARGET_DISPLAY)),
                taskInventory = { if (activityStarted) listOf(task) else emptyList() },
                adapters =
                    LaunchServiceAdapters(
                        createIntent = { _, _ -> Any() },
                        createOptions = { request ->
                            launchOptions = request
                            options
                        },
                        startActivityAsUser = { arguments ->
                            activityStarted = true
                            activityArguments = arguments
                            START_SUCCESS
                        },
                        startResult = { START_SUCCESS },
                    ),
            )

        val result = service.launch(request(displayId = TARGET_DISPLAY))

        assertEquals(
            DisplayLaunchOptions(TARGET_DISPLAY, LaunchWindowingMode.FULLSCREEN),
            launchOptions,
        )
        assertEquals(12, activityArguments?.size)
        assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK, activityArguments?.get(8))
        assertSame(options, activityArguments?.get(10))
        assertEquals(0, activityArguments?.get(11))
        assertEquals(task.getTaskId(), result.getTaskId())
    }

    @Test
    fun negativeDisplayIdIsAnInvalidArgumentAndDoesNotStartAnActivity() {
        var activityStarted = false
        val service =
            service(
                displayInventory = mapOf(TARGET_DISPLAY to display(TARGET_DISPLAY)),
                taskInventory = { emptyList() },
                adapters =
                    LaunchServiceAdapters(
                        startActivityAsUser = {
                            activityStarted = true
                            START_SUCCESS
                        }
                    ),
            )

        val failure =
            assertThrows(GuestFailure::class.java) {
                service.launch(request(displayId = INVALID_DISPLAY))
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, failure.code)
        assertEquals(INVALID_DISPLAY.toString(), failure.detail["display_id"])
        assertFalse(activityStarted)
    }

    @Test
    fun unknownDisplayIdIsNotFoundAndDoesNotStartAnActivity() {
        var activityStarted = false
        val service =
            service(
                displayInventory = emptyMap(),
                taskInventory = { emptyList() },
                adapters =
                    LaunchServiceAdapters(
                        startActivityAsUser = {
                            activityStarted = true
                            START_SUCCESS
                        }
                    ),
            )

        val failure =
            assertThrows(GuestFailure::class.java) {
                service.launch(request(displayId = UNKNOWN_DISPLAY))
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, failure.code)
        assertEquals(UNKNOWN_DISPLAY.toString(), failure.detail["display_id"])
        assertFalse(activityStarted)
    }

    private fun service(
        displayInventory: Map<Int, DisplayInfo>,
        taskInventory: () -> List<TaskInfo>,
        adapters: LaunchServiceAdapters,
    ): LaunchService {
        val events = EventBus()
        val tasks =
            TaskService(
                events = events,
                callbacks = {},
                readTaskList = taskInventory,
            )
        tasks.refresh()
        return LaunchService.withAdapters(
            tasks = tasks,
            displays =
                DisplayService(
                    events = events,
                    callbacks = {},
                    readDisplayInventory = { displayInventory },
                ),
            system = { error("the injected intent factory does not need a Context") },
            adapters = adapters,
        )
    }

    private fun request(displayId: Int): LaunchApplication =
        LaunchApplication.newBuilder()
            .setPackage(TARGET_PACKAGE)
            .setDisplayId(displayId)
            .setMode(LaunchMode.LAUNCH_MODE_BRING_TO_FRONT_OR_START)
            .build()

    private fun display(displayId: Int): DisplayInfo =
        DisplayInfo.newBuilder()
            .setDisplayId(displayId)
            .setMode(DisplayMode.newBuilder().setWidthPx(960).setHeightPx(1700))
            .build()

    private fun task(
        taskId: Int,
        displayId: Int,
        packageName: String = TARGET_PACKAGE,
    ): TaskInfo =
        TaskInfo.newBuilder()
            .setTaskId(taskId)
            .setDisplayId(displayId)
            .setPackage(packageName)
            .build()

    private companion object {
        const val TARGET_PACKAGE = "io.apkrun.fixture.hellotext"
        const val OTHER_PACKAGE = "io.apkrun.fixture.hellocompose"
        const val TARGET_DISPLAY = 7
        const val UNKNOWN_DISPLAY = 42
        const val INVALID_DISPLAY = -1
        const val START_SUCCESS = 0
    }
}
