package io.apkrun.guest.daemon

import android.app.ActivityOptions
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchMode
import io.apkrun.guest.protocol.v1.LaunchOutcome
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.TaskInfo

/** How long a launch waits for its task to appear on the display (guest-components.md §6.4). */
private const val TASK_APPEARANCE_MILLIS = 2_000L

/** The poll interval of that wait. */
private const val TASK_POLL_MILLIS = 100L

/**
 * `LaunchApplication` (launch.v1, guest-components.md §6.4). The activity starts through the system
 * context with `ActivityOptions.setLaunchDisplayId`. When the package already has a task on another
 * display, that task is moved first. The result is the task that appears on the display within 2 s.
 * Without one the answer is TIMEOUT.
 */
class LaunchService(
    private val tasks: TaskService,
    private val displays: DisplayService,
    private val context: () -> Context,
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
            if (onTarget != null && !clearTask) LaunchOutcome.LAUNCH_OUTCOME_BROUGHT_TO_FRONT
            else LaunchOutcome.LAUNCH_OUTCOME_STARTED
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

    private fun startActivity(request: LaunchApplication, displayId: Int) {
        val intent = Intent(Intent.ACTION_MAIN)
        if (request.hasComponent()) {
            val component =
                ComponentName.unflattenFromString(request.getComponent())
                    ?: throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "the component is not valid",
                    )
            intent.setComponent(component)
        } else {
            intent.addCategory(Intent.CATEGORY_LAUNCHER).setPackage(request.getPackage())
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
        val options = launchOptions(displayId)
        try {
            context().startActivity(intent, options)
        } catch (error: ActivityNotFoundException) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the package has no launcher activity",
                mapOf("package" to request.getPackage()),
            )
        }
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
