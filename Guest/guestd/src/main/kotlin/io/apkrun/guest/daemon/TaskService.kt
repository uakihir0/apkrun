package io.apkrun.guest.daemon

import android.content.ComponentName
import io.apkrun.guest.protocol.v1.DisplayEmpty
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.TaskInfo
import io.apkrun.guest.protocol.v1.TaskVanished
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import io.apkrun.guest.runtime.SystemServices

/** The most tasks that one `getTasks` call asks for. */
private const val MAXIMUM_TASKS = 100

/** `Display.INVALID_DISPLAY`: lists the tasks of every display in `getTasks`. */
private const val INVALID_DISPLAY = -1

/**
 * Task events and task control (launch.v1, input.v1, guest-protocol.md §8.3, guest-components.md
 * §6.1). The `ITaskStackListener` callback only says that something changed. The list of tasks is
 * then read with `getTasks`, and the events are the differences from the last list.
 */
class TaskService(
    private val events: EventBus,
    /** Runs a refresh on the `apkrun-callbacks` thread (see [DisplayService]). */
    private val callbacks: (() -> Unit) -> Unit,
) {
    private val known = LinkedHashMap<Int, TaskInfo>()

    /**
     * Registers the task listener and reads the first list. A missing listener only fails task
     * events.
     */
    fun start() {
        val listenerInterface = HiddenApi.classOrNull("android.app.ITaskStackListener")
        if (listenerInterface == null) {
            AgentLog.warning("task events are unavailable: the listener interface is missing")
        } else {
            val listener = HiddenApi.listener(listenerInterface) { callbacks { refresh() } }
            try {
                SystemServices.activityTask.call("registerTaskStackListener", listener)
            } catch (error: Exception) {
                AgentLog.warning("task events are unavailable: ${error.javaClass.simpleName}")
            }
        }
        refreshAtStart()
    }

    /**
     * The first list of tasks. A failure here only fails task events, and the agent keeps running.
     */
    private fun refreshAtStart() {
        try {
            refresh()
        } catch (error: Exception) {
            AgentLog.warning("the task list is unavailable: ${error.javaClass.simpleName}")
        }
    }

    /** The tasks that Android reports now, most recent first. */
    fun list(): List<TaskInfo> = readTasks()

    /** The display of the most recent visible task, or display 0 when no task is visible. */
    fun focusedDisplayId(): Int = list().firstOrNull { it.getVisible() }?.getDisplayId() ?: 0

    /** Moves the focus to the top task of [displayId] (`setFocusedTask`, input.md §7.2). */
    fun focus(displayId: Int) {
        val task =
            list().firstOrNull { it.getDisplayId() == displayId }
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "no task is on the display",
                    mapOf("display_id" to displayId.toString()),
                )
        SystemServices.activityTask.call("setFocusedTask", task.getTaskId())
    }

    /** Moves a root task to [displayId] (`moveRootTaskToDisplay`). */
    fun moveToDisplay(taskId: Int, displayId: Int) {
        SystemServices.activityTask.call("moveRootTaskToDisplay", taskId, displayId)
    }

    /**
     * Publishes the differences between the last list of tasks and the list that Android reports
     * now. It returns the list that it read, so that a caller answers with the tasks it published.
     */
    @Synchronized
    fun refresh(): List<TaskInfo> {
        val current = readTasks().associateBy { it.getTaskId() }
        for ((id, task) in current) {
            val before = known[id]
            if (before == null) {
                events.publish { it.setTaskAppeared(task) }
            } else if (before != task) {
                events.publish { it.setTaskChanged(task) }
            }
        }
        for ((id, task) in known) {
            if (id !in current) {
                events.publish {
                    it.setTaskVanished(
                        TaskVanished.newBuilder()
                            .setTaskId(id)
                            .setDisplayId(task.getDisplayId())
                            .setPackage(task.getPackage())
                    )
                }
            }
        }
        val displaysBefore = known.values.map { it.getDisplayId() }.toSet()
        val displaysNow = current.values.map { it.getDisplayId() }.toSet()
        for (displayId in displaysBefore - displaysNow) {
            if (displayId != 0) {
                events.publish {
                    it.setDisplayEmpty(DisplayEmpty.newBuilder().setDisplayId(displayId))
                }
            }
        }
        known.clear()
        known.putAll(current)
        return current.values.toList()
    }

    private fun readTasks(): List<TaskInfo> {
        val raw =
            SystemServices.activityTask.call("getTasks", *taskListArguments()) ?: return emptyList()
        val items =
            (raw as? List<*>) ?: (HiddenApi.read(raw, "list") as? List<*>) ?: return emptyList()
        return items.filterNotNull().map { toProto(it) }
    }

    /**
     * The arguments of `getTasks` for the variant of this image. The 4-parameter form takes the
     * display and lists the tasks of every display with INVALID_DISPLAY. The 1-parameter form lists
     * the most recent tasks.
     */
    private fun taskListArguments(): Array<Any?> =
        if (SystemServices.activityTask.parameterCount("getTasks") == 4) {
            arrayOf(MAXIMUM_TASKS, false, false, INVALID_DISPLAY)
        } else {
            arrayOf(MAXIMUM_TASKS)
        }

    private fun toProto(info: Any): TaskInfo {
        val base = HiddenApi.read(info, "baseActivity") as? ComponentName
        val top = HiddenApi.read(info, "topActivity") as? ComponentName
        val configuration = HiddenApi.read(info, "configuration")
        val windowConfiguration = configuration?.let { HiddenApi.read(it, "windowConfiguration") }
        val windowingMode =
            (windowConfiguration?.let { HiddenApi.read(it, "windowingMode") } as? Number)?.toInt()
        return TaskInfo.newBuilder()
            .setTaskId((HiddenApi.read(info, "taskId") as? Number)?.toInt() ?: 0)
            .setDisplayId((HiddenApi.read(info, "displayId") as? Number)?.toInt() ?: 0)
            .setPackage(base?.packageName ?: top?.packageName ?: "")
            .setBaseComponent(base?.flattenToShortString() ?: "")
            .setTopComponent(top?.flattenToShortString() ?: "")
            .setWindowingMode(windowingMode ?: 0)
            .setVisible(HiddenApi.read(info, "isVisible") as? Boolean ?: false)
            .build()
    }
}
