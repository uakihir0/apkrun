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
 * `LaunchApplication` (launch.v1, guest-components.md §6.4). The activity starts through
 * `startActivityAsUser` with the shell package as the calling package, because the system context's
 * package does not belong to the agent's uid. The activity is placed on its display with
 * `ActivityOptions.setLaunchDisplayId`. When the package already has a task on another display,
 * that task is moved first. The result is the task that appears on the display within 2 s, and
 * without one the answer is TIMEOUT.
 */
class LaunchService(
    private val tasks: TaskService,
    private val displays: DisplayService,
    private val system: () -> Context,
) {
    /** Launches the package of [request] on its display, and returns the task that it has there. */
    fun launch(request: LaunchApplication): LaunchResult {
        val pkg = request.getPackage()
        if (!isPackageName(pkg)) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the package name is not valid",
            )
        }
        val displayId = request.getDisplayId()
        if (displayId < 0 || displays.modeOf(displayId) == null) {
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

    /**
     * Starts the launcher activity of the package, or the request's component, and maps the result
     * code.
     */
    private fun startActivity(request: LaunchApplication, displayId: Int) {
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
                // The launcher activity comes from PackageManager, as getLaunchIntentForPackage
                // resolves it, and the
                // start names the explicit component. A package-only intent is resolved against the
                // caller's
                // visibility, which the shell uid does not have for every package.
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
        var flags = Intent.FLAG_ACTIVITY_NEW_TASK
        if (request.getMode() == LaunchMode.LAUNCH_MODE_CLEAR_TASK) {
            flags = flags or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        intent.addFlags(flags)
        val result =
            SystemServices.activityTask.call(
                "startActivityAsUser",
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
                launchOptions(displayId),
                CURRENT_USER_ID,
            ) as? Int ?: Int.MIN_VALUE
        AgentLog.info(
            "the activity start for ${request.getPackage()} on display $displayId returned $result"
        )
        when (result) {
            startResult("START_SUCCESS"),
            startResult("START_TASK_TO_FRONT"),
            startResult("START_DELIVERED_TO_TOP") -> Unit
            startResult("START_INTENT_NOT_RESOLVED"),
            startResult("START_CLASS_NOT_FOUND") ->
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "the package has no activity for the launch",
                    mapOf("package" to request.getPackage()),
                )
            startResult("START_PERMISSION_DENIED") ->
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
     * A start result of `ActivityManager`, read from this image. Android renumbers these between
     * releases (on build 16373615 `START_INTENT_NOT_RESOLVED` is -91), so the values are not
     * written into the agent.
     */
    private fun startResult(name: String): Int =
        try {
            checkNotNull(HiddenApi.classOrNull("android.app.ActivityManager"))
                .getField(name)
                .getInt(null)
        } catch (error: ReflectiveOperationException) {
            Int.MIN_VALUE
        }

    /**
     * `ActivityOptions` that place the activity on [displayId]. `setLaunchDisplayId` is a hidden
     * method.
     */
    private fun launchOptions(displayId: Int): android.os.Bundle {
        val options = ActivityOptions.makeBasic()
        try {
            ActivityOptions::class
                .java
                .getMethod("setLaunchDisplayId", Int::class.javaPrimitiveType)
                .invoke(options, displayId)
        } catch (error: ReflectiveOperationException) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                "ActivityOptions.setLaunchDisplayId is not available on this image",
            )
        }
        return options.toBundle()
    }

    private fun awaitTask(pkg: String, displayId: Int): TaskInfo? {
        val deadline = System.currentTimeMillis() + TASK_APPEARANCE_MILLIS
        while (true) {
            val task =
                tasks.list().firstOrNull {
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

    private fun isPackageName(name: String): Boolean {
        val parts = name.split('.')
        return parts.size >= 2 &&
            parts.all { part ->
                part.isNotEmpty() &&
                    part[0].isLetter() &&
                    part.all { it.isLetterOrDigit() || it == '_' }
            }
    }
}
