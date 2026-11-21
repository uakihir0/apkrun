package io.apkrun.guest.daemon

import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchMode
import io.apkrun.guest.protocol.v1.LaunchOutcome
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.StopApplication
import io.apkrun.guest.protocol.v1.StopMode
import io.apkrun.guest.protocol.v1.TaskInfo
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import io.apkrun.guest.runtime.SystemServices

/** How long a launch waits for its task to appear on the display (guest-components.md §6.4). */
private const val TASK_APPEARANCE_MILLIS = 2_000L

/** The poll interval of that wait. */
private const val TASK_POLL_MILLIS = 100L

/**
 * The package that the agent's uid belongs to. The activity start names it as the calling package.
 */
private const val SHELL_PACKAGE = "com.android.shell"

/**
 * The user that the development agent starts activities for: the system user (guest-components.md
 * §5).
 */
private const val CURRENT_USER_ID = 0

/**
 * Android boundary adapters used by [LaunchService]. The default implementation calls the
 * framework; tests replace these functions to inspect the launch arguments without an Android VM.
 */
internal enum class LaunchWindowingMode {
    FULLSCREEN
}

internal data class DisplayLaunchOptions(
    val displayId: Int,
    val windowingMode: LaunchWindowingMode,
)

internal data class LaunchServiceAdapters(
    val createIntent: (LaunchApplication, () -> Context) -> Any? = ::createLaunchIntent,
    val createOptions: (DisplayLaunchOptions) -> Any? = ::createLaunchOptions,
    val startActivityAsUser: (Array<out Any?>) -> Any? = ::invokeStartActivityAsUser,
    val startResult: (String) -> Int = ::activityStartResult,
    val forceStopPackage: (String, Int) -> Unit = { packageName, userId ->
        SystemServices.activity.call("forceStopPackage", packageName, userId)
        Unit
    },
)

/**
 * `LaunchApplication` (launch.v1, guest-components.md §6.4). The activity starts through
 * `startActivityAsUser` with the shell package as the calling package, because the system context's
 * package does not belong to the agent's uid. The activity is placed on its display with
 * `ActivityOptions.setLaunchDisplayId`. When the package already has a task on another display,
 * that task is moved first. The result is the task that appears on the display within 2 s, and
 * without one the answer is TIMEOUT.
 */
class LaunchService
private constructor(
    private val tasks: TaskService,
    private val displays: DisplayService,
    private val system: () -> Context,
    private val adapters: LaunchServiceAdapters,
) {
    constructor(
        tasks: TaskService,
        displays: DisplayService,
        system: () -> Context,
    ) : this(tasks, displays, system, LaunchServiceAdapters())

    internal companion object {
        /** Creates a service with fake framework adapters for focused JVM tests. */
        fun withAdapters(
            tasks: TaskService,
            displays: DisplayService,
            system: () -> Context,
            adapters: LaunchServiceAdapters,
        ): LaunchService = LaunchService(tasks, displays, system, adapters)
    }

    /** Launches the package of [request] on its display, and returns the task that it has there. */
    fun launch(request: LaunchApplication): LaunchResult {
        val pkg = request.getPackage()
        if (!PackageName.isValid(pkg)) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the package name is not valid",
            )
        }
        val displayId = request.getDisplayId()
        if (displayId < 0) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the display ID is not valid",
                mapOf("display_id" to displayId.toString()),
            )
        }
        if (displays.modeOf(displayId) == null) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the display is not known",
                mapOf("display_id" to displayId.toString()),
            )
        }
        val clearTask = request.getMode() == LaunchMode.LAUNCH_MODE_CLEAR_TASK
        val existing = tasks.list().filter { it.getPackage() == pkg }
        val onTarget = existing.firstOrNull { it.getDisplayId() == displayId }
        var outcome =
            if (onTarget != null && !clearTask) {
                LaunchOutcome.LAUNCH_OUTCOME_BROUGHT_TO_FRONT
            } else {
                LaunchOutcome.LAUNCH_OUTCOME_STARTED
            }
        if (onTarget == null && !clearTask && existing.isNotEmpty()) {
            tasks.moveToDisplay(existing.first().getTaskId(), displayId)
            outcome = LaunchOutcome.LAUNCH_OUTCOME_MOVED_FROM_DISPLAY
        }
        startActivity(request, displayId)
        val task =
            awaitTask(pkg, displayId)
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT,
                    "the task did not appear on the display within $TASK_APPEARANCE_MILLIS ms",
                    mapOf("display_id" to displayId.toString()),
                )
        return LaunchResult.newBuilder()
            .setTaskId(task.getTaskId())
            .setComponent(task.getTopComponent().ifEmpty { task.getBaseComponent() })
            .setOutcome(outcome)
            .build()
    }

    /** Finishes every task, or force-stops every task and process, of the requested package. */
    suspend fun stop(request: StopApplication) {
        val pkg = request.getPackage()
        if (!PackageName.isValid(pkg)) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the package name is not valid",
            )
        }
        when (request.getMode()) {
            StopMode.STOP_MODE_FINISH_TASKS -> tasks.removeAllForPackage(pkg)
            StopMode.STOP_MODE_FORCE_STOP -> {
                adapters.forceStopPackage(pkg, CURRENT_USER_ID)
                tasks.awaitPackageTasksDisappear(pkg)
            }
            StopMode.STOP_MODE_UNSPECIFIED,
            StopMode.UNRECOGNIZED ->
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                    "the stop mode is not supported",
                )
        }
    }

    /**
     * Starts the launcher activity of the package, or the request's component, and maps the result
     * code.
     */
    private fun startActivity(request: LaunchApplication, displayId: Int) {
        val intent = adapters.createIntent(request, system)
        var flags = Intent.FLAG_ACTIVITY_NEW_TASK
        if (request.getMode() == LaunchMode.LAUNCH_MODE_CLEAR_TASK) {
            flags = flags or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        (intent as? Intent)?.addFlags(flags)
        val result =
            adapters.startActivityAsUser(
                arrayOf(
                    null,
                    SHELL_PACKAGE,
                    null,
                    intent,
                    null,
                    null,
                    null,
                    0,
                    flags,
                    null,
                    adapters.createOptions(
                        DisplayLaunchOptions(displayId, LaunchWindowingMode.FULLSCREEN)
                    ),
                    CURRENT_USER_ID,
                )
            ) as? Int ?: Int.MIN_VALUE
        AgentLog.info(
            "the activity start for ${request.getPackage()} on display $displayId returned $result"
        )
        when (result) {
            adapters.startResult("START_SUCCESS"),
            adapters.startResult("START_TASK_TO_FRONT"),
            adapters.startResult("START_DELIVERED_TO_TOP") -> Unit
            adapters.startResult("START_INTENT_NOT_RESOLVED"),
            adapters.startResult("START_CLASS_NOT_FOUND") ->
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "the package has no activity for the launch",
                    mapOf("package" to request.getPackage()),
                )
            adapters.startResult("START_PERMISSION_DENIED") ->
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_PERMISSION_DENIED,
                    "Android refused the start",
                )
            else ->
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INTERNAL,
                    "the activity start returned a result code",
                    mapOf("start_result" to result.toString()),
                )
        }
    }

    /**
     * Waits for the task on the display. Each check is a refresh, which publishes the tasks that
     * appeared (guest-protocol.md §6): the host has the event before the answer that follows the
     * launch.
     */
    private fun awaitTask(pkg: String, displayId: Int): TaskInfo? {
        val deadline = System.currentTimeMillis() + TASK_APPEARANCE_MILLIS
        while (true) {
            val task =
                tasks.refresh().firstOrNull {
                    it.getPackage() == pkg && it.getDisplayId() == displayId
                }
            if (task != null) {
                return task
            }
            if (System.currentTimeMillis() >= deadline) {
                return null
            }
            Thread.sleep(TASK_POLL_MILLIS)
        }
    }
}

private fun createLaunchIntent(request: LaunchApplication, system: () -> Context): Intent {
    val intent =
        if (request.hasComponent()) {
            val component =
                ComponentName.unflattenFromString(request.getComponent())
                    ?: throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "the component is not valid",
                    )
            Intent(Intent.ACTION_MAIN).setComponent(component)
        } else {
            // The launcher activity comes from PackageManager, and the start names the explicit
            // component. A package-only intent is resolved against the caller's visibility, which
            // the shell uid does not have for every package.
            system().packageManager.getLaunchIntentForPackage(request.getPackage())
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "the package has no launcher activity",
                    mapOf("package" to request.getPackage()),
                )
        }
    if (request.hasAction()) {
        intent.action = request.getAction()
    }
    if (request.hasDataUri()) {
        intent.data = android.net.Uri.parse(request.getDataUri())
    }
    return intent
}

/**
 * ActivityOptions that place the activity fullscreen on [displayId], per display-and-windowing.md
 * §4.
 */
private fun createLaunchOptions(request: DisplayLaunchOptions): android.os.Bundle {
    val options = ActivityOptions.makeBasic()
    invokeIntegerOption(options, "setLaunchDisplayId", request.displayId)
    when (request.windowingMode) {
        LaunchWindowingMode.FULLSCREEN -> {
            val windowConfiguration =
                HiddenApi.classOrNull("android.app.WindowConfiguration")
                    ?: throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                        "WindowConfiguration.WINDOWING_MODE_FULLSCREEN is not available on this image",
                    )
            val fullscreenMode =
                try {
                    windowConfiguration.getField("WINDOWING_MODE_FULLSCREEN").getInt(null)
                } catch (error: ReflectiveOperationException) {
                    throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                        "WindowConfiguration.WINDOWING_MODE_FULLSCREEN is not available on this image",
                    )
                }
            invokeIntegerOption(options, "setLaunchWindowingMode", fullscreenMode)
        }
    }
    return options.toBundle()
}

private fun invokeIntegerOption(options: ActivityOptions, methodName: String, value: Int) {
    try {
        ActivityOptions::class
            .java
            .getMethod(methodName, Int::class.javaPrimitiveType)
            .invoke(options, value)
    } catch (error: ReflectiveOperationException) {
        throw GuestFailure(
            GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
            "ActivityOptions.$methodName is not available on this image",
        )
    }
}

private fun invokeStartActivityAsUser(arguments: Array<out Any?>): Any? =
    SystemServices.activityTask.call("startActivityAsUser", *arguments)

/**
 * A start result of `ActivityManager`, read from this image. Android renumbers these between
 * releases (on build 16373615 `START_INTENT_NOT_RESOLVED` is -91), so the values are not written
 * into the agent.
 */
private fun activityStartResult(name: String): Int =
    try {
        checkNotNull(HiddenApi.classOrNull("android.app.ActivityManager"))
            .getField(name)
            .getInt(null)
    } catch (error: ReflectiveOperationException) {
        Int.MIN_VALUE
    }
