package io.apkrun.guest.daemon

import android.content.ComponentName
import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.ClearPolicy
import io.apkrun.guest.protocol.v1.DisplayEmpty
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.TaskInfo
import io.apkrun.guest.protocol.v1.TaskVanished
import io.apkrun.guest.protocol.v1.TasksCleared
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import io.apkrun.guest.runtime.SystemServices
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

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
    /** Task inventory adapter, replaceable by a fake in JVM tests. */
    private val readTaskList: (() -> List<TaskInfo>)? = null,
    /** Task removal adapter, replaceable by a fake in JVM tests. */
    private val removeTaskById: (Int) -> Unit = { taskId ->
        SystemServices.activityTask.call("removeTask", taskId)
    },
    /** Task move adapter, replaceable by a fake in JVM tests. */
    private val moveTaskById: (Int, Int) -> Unit = { taskId, displayId ->
        SystemServices.activityTask.call("moveRootTaskToDisplay", taskId, displayId)
    },
    /** Focus adapter, replaceable by a fake in JVM tests. */
    private val focusTaskById: (Int) -> Unit = { taskId ->
        SystemServices.activityTask.call("setFocusedTask", taskId)
    },
    private val nowMillis: () -> Long = { System.nanoTime() / NANOS_PER_MILLI },
    private val waitMillis: suspend (Long) -> Unit = { delay(it) },
) {
    private val known = LinkedHashMap<Int, TaskInfo>()
    private val removalLock = Mutex()
    private val displayClearLocks = ConcurrentHashMap<Int, Mutex>()
    private val clearingDisplays = ConcurrentHashMap.newKeySet<Int>()

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
    fun list(): List<TaskInfo> = readCurrentTasks()

    /** The display of the most recent visible task, or display 0 when no task is visible. */
    fun focusedDisplayId(): Int = list().firstOrNull { it.getVisible() }?.getDisplayId() ?: 0

    /** Moves the focus to the top task of [displayId] (`setFocusedTask`, input.md §7.2). */
    fun focus(displayId: Int) {
        if (displayId < 0) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the display ID is not valid",
                mapOf("display_id" to displayId.toString()),
            )
        }
        val task =
            list().firstOrNull { it.getDisplayId() == displayId }
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "no task is on the display",
                    mapOf("display_id" to displayId.toString()),
                )
        focusTaskById(task.getTaskId())
    }

    /** Moves a root task to [displayId] (`moveRootTaskToDisplay`). */
    fun moveToDisplay(taskId: Int, displayId: Int) {
        SystemServices.activityTask.call("moveRootTaskToDisplay", taskId, displayId)
    }

    /**
     * Removes every task for [packageName] and waits until a refresh observes their disappearance.
     * Each refresh publishes the existing `TaskVanished` events before this method returns, so the
     * dispatcher sends them before the `StopApplication` response (guest-protocol.md §6, §7.1).
     */
    suspend fun removeAllForPackage(packageName: String) {
        removalLock.withLock {
            val context = currentCoroutineContext()
            val deadline = nowMillis() + TASK_REMOVAL_TIMEOUT_MILLIS
            context.ensureActive()
            val packageTasks = refresh().filter { it.getPackage() == packageName }
            context.ensureActive()
            packageTasks.forEach {
                context.ensureActive()
                removeTaskById(it.getTaskId())
            }
            awaitPackageTasksDisappearLocked(packageName, deadline)
        }
    }

    /**
     * Waits until Android no longer reports [packageName], publishing `TaskVanished` before return.
     * Used after `IActivityManager.forceStopPackage`, which removes tasks without calling `removeTask`.
     */
    suspend fun awaitPackageTasksDisappear(packageName: String) {
        removalLock.withLock {
            awaitPackageTasksDisappearLocked(
                packageName,
                nowMillis() + TASK_REMOVAL_TIMEOUT_MILLIS,
            )
        }
    }

    private suspend fun awaitPackageTasksDisappearLocked(packageName: String, deadline: Long) {
        val context = currentCoroutineContext()
        while (true) {
            context.ensureActive()
            val remainingTasks = refresh().filter { it.getPackage() == packageName }
            context.ensureActive()
            if (remainingTasks.isEmpty()) {
                return
            }
            val remainingMillis = deadline - nowMillis()
            if (remainingMillis <= 0) {
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT,
                    "the package tasks did not disappear after stopping",
                    mapOf("package" to packageName),
                )
            }
            waitMillis(minOf(TASK_POLL_MILLIS, remainingMillis))
        }
    }

    /**
     * Clears every task on [request]'s display, then publishes `TasksCleared`. A clear suppresses
     * `DisplayEmpty` for that display while task events are reconciled, so the host observes one
     * completion signal for the operation (guest-protocol.md §8.3).
     */
    suspend fun clearDisplay(request: ClearDisplay) {
        val displayId = request.displayId
        if (displayId < 0) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the display ID is not valid",
                mapOf("display_id" to displayId.toString()),
            )
        }
        val policy =
            when (request.policy) {
                ClearPolicy.CLEAR_POLICY_FINISH_TASKS -> ClearAction.FINISH
                ClearPolicy.CLEAR_POLICY_MOVE_TO_DEFAULT_DISPLAY -> {
                    if (displayId == 0) {
                        throw GuestFailure(
                            GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                            "display 0 cannot be moved to itself",
                            mapOf("display_id" to displayId.toString()),
                        )
                    }
                    ClearAction.MOVE_TO_DEFAULT
                }
                ClearPolicy.CLEAR_POLICY_UNSPECIFIED,
                ClearPolicy.UNRECOGNIZED ->
                    throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "the clear policy is not supported",
                    )
            }

        displayClearLocks
            .computeIfAbsent(displayId) { Mutex() }
            .withLock {
                val context = currentCoroutineContext()
                val deadline = nowMillis() + TASK_CLEAR_TIMEOUT_MILLIS
                val attemptedTaskIds = mutableSetOf<Int>()
                clearingDisplays.add(displayId)
                try {
                    while (true) {
                        context.ensureActive()
                        val remaining =
                            synchronized(this) {
                                val current = refresh().filter { it.getDisplayId() == displayId }
                                if (current.isEmpty()) {
                                    events.publish {
                                        it.setTasksCleared(
                                            TasksCleared.newBuilder()
                                                .setDisplayId(displayId)
                                                .setRemainingTasks(0)
                                        )
                                    }
                                }
                                current
                            }
                        context.ensureActive()
                        if (remaining.isEmpty()) {
                            return
                        }

                        val remainingMillis = deadline - nowMillis()
                        if (remainingMillis <= 0) {
                            throw GuestFailure(
                                GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT,
                                "the display tasks did not clear before the deadline",
                                mapOf(
                                    "display_id" to displayId.toString(),
                                    "remaining_tasks" to remaining.size.toString(),
                                ),
                            )
                        }
                        remaining
                            .filter { attemptedTaskIds.add(it.getTaskId()) }
                            .forEach { task ->
                                context.ensureActive()
                                removalLock.withLock {
                                    context.ensureActive()
                                    if (deadline - nowMillis() <= 0) {
                                        throw GuestFailure(
                                            GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT,
                                            "the display tasks did not clear before the deadline",
                                            mapOf(
                                                "display_id" to displayId.toString(),
                                                "remaining_tasks" to remaining.size.toString(),
                                            ),
                                        )
                                    }
                                    val stillOnDisplay =
                                        readCurrentTasks().any {
                                            it.getTaskId() == task.getTaskId() &&
                                                it.getDisplayId() == displayId
                                        }
                                    if (stillOnDisplay) {
                                        when (policy) {
                                            ClearAction.FINISH -> removeTaskById(task.getTaskId())
                                            ClearAction.MOVE_TO_DEFAULT ->
                                                moveTaskById(task.getTaskId(), 0)
                                        }
                                    }
                                }
                            }
                        waitMillis(minOf(TASK_POLL_MILLIS, remainingMillis))
                    }
                } finally {
                    clearingDisplays.remove(displayId)
                }
            }
    }

    /**
     * Publishes the differences between the last list of tasks and the list that Android reports
     * now. It returns the list that it read, so that a caller answers with the tasks it published.
     */
    @Synchronized
    fun refresh(): List<TaskInfo> {
        val current = readCurrentTasks().associateBy { it.getTaskId() }
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
            if (displayId != 0 && displayId !in clearingDisplays) {
                events.publish {
                    it.setDisplayEmpty(DisplayEmpty.newBuilder().setDisplayId(displayId))
                }
            }
        }
        known.clear()
        known.putAll(current)
        return current.values.toList()
    }

    private fun readTasksFromSystem(): List<TaskInfo> {
        val raw =
            SystemServices.activityTask.call("getTasks", *taskListArguments()) ?: return emptyList()
        val items =
            (raw as? List<*>) ?: (HiddenApi.read(raw, "list") as? List<*>) ?: return emptyList()
        return items.filterNotNull().map { toProto(it) }
    }

    private fun readCurrentTasks(): List<TaskInfo> = readTaskList?.invoke() ?: readTasksFromSystem()

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

    private companion object {
        /**
         * Leaves time for the host to receive the response within the five-second default deadline.
         */
        const val TASK_REMOVAL_TIMEOUT_MILLIS = 4_000L
        const val TASK_CLEAR_TIMEOUT_MILLIS = 4_000L
        const val TASK_POLL_MILLIS = 100L
        const val NANOS_PER_MILLI = 1_000_000L

        enum class ClearAction {
            FINISH,
            MOVE_TO_DEFAULT,
        }
    }
}
