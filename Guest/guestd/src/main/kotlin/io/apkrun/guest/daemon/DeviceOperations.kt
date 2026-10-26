package io.apkrun.guest.daemon

import android.os.SystemClock
import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Health
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.ListPackages
import io.apkrun.guest.protocol.v1.ListTasks
import io.apkrun.guest.protocol.v1.MoveTaskToDisplay
import io.apkrun.guest.protocol.v1.PackageInfo
import io.apkrun.guest.protocol.v1.PackageList
import io.apkrun.guest.protocol.v1.QueryPackage
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.Shutdown
import io.apkrun.guest.protocol.v1.Snapshot
import io.apkrun.guest.protocol.v1.StopApplication
import io.apkrun.guest.protocol.v1.SystemState
import io.apkrun.guest.protocol.v1.TaskList
import io.apkrun.guest.runtime.HiddenApi
import io.apkrun.guest.runtime.ServiceMethodMissing
import io.apkrun.guest.runtime.SystemServiceWrapper
import io.apkrun.guest.runtime.SystemServices

/**
 * The operations of the agent on the device, over the services (guest-components.md §6.1). The
 * snapshot reports what the services know. The IME, notification, and clipboard fields keep their
 * defaults until #72, #54, and #55.
 */
class DeviceOperations(
    private val displays: DisplayService,
    private val tasks: TaskService,
    private val launch: LaunchService,
    private val packages: PackageService,
    private val health: HealthService,
    private val system: SystemOperations,
    private val appProcessMonitoringAvailable: () -> Boolean,
    private val hasMethod: (SystemServiceWrapper, String) -> Boolean = { wrapper, method ->
        wrapper.supports(method)
    },
) : AgentOperations {
    /** Capabilities whose backing framework APIs resolved on this image. */
    fun supportedCapabilities(): Set<GuestCapability> = buildSet {
        add(GuestCapability.CORE)
        if (
            hasMethod(SystemServices.display, "getDisplayIds") &&
                hasMethod(SystemServices.display, "getDisplayInfo") &&
                hasMethod(SystemServices.display, "registerCallback") &&
                hasMethod(SystemServices.window, "setForcedDisplayDensityForUser") &&
                hasMethod(SystemServices.window, "setDisplayImePolicy")
        ) {
            add(GuestCapability.DISPLAY)
        }
        if (
            hasMethod(SystemServices.activityTask, "getTasks") &&
                hasMethod(SystemServices.activityTask, "registerTaskStackListener") &&
                hasMethod(SystemServices.activityTask, "startActivityAsUser") &&
                hasMethod(SystemServices.activityTask, "moveRootTaskToDisplay") &&
                hasMethod(SystemServices.activityTask, "removeTask") &&
                hasMethod(SystemServices.activityTask, "setFocusedTask") &&
                hasMethod(SystemServices.activity, "forceStopPackage")
        ) {
            add(GuestCapability.LAUNCH)
        }
        if (
            hasMethod(SystemServices.activityTask, "getTasks") &&
                hasMethod(SystemServices.activityTask, "setFocusedTask") &&
                hasMethod(SystemServices.input, "injectInputEvent")
        ) {
            add(GuestCapability.INPUT)
        }
        add(GuestCapability.INPUT_ACK_TRACE)
        add(GuestCapability.PACKAGES)
        if (appProcessMonitoringAvailable()) {
            add(GuestCapability.HEALTH)
        }
        if (hasMethod(SystemServices.power, "shutdown")) {
            add(GuestCapability.SYSTEM)
        }
    }

    /** Hidden API methods absent from the current image, for GetHealth diagnostics. */
    fun missingSystemMethods(): List<String> =
        SystemServices.all.flatMap { wrapper ->
            wrapper.missingMethods.map { method -> "${wrapper.serviceName}.$method" }
        }

    override fun snapshot(): Snapshot {
        val displaySnapshot =
            try {
                displays.readDisplays().values.toList()
            } catch (_: ServiceMethodMissing) {
                emptyList()
            } catch (_: LinkageError) {
                emptyList()
            }
        val taskSnapshot =
            try {
                tasks.list()
            } catch (_: ServiceMethodMissing) {
                emptyList()
            } catch (_: LinkageError) {
                emptyList()
            }
        val focusedDisplayId = taskSnapshot.firstOrNull { it.getVisible() }?.getDisplayId() ?: 0
        return Snapshot.newBuilder()
            .setSystem(systemState())
            .addAllDisplays(displaySnapshot)
            .addAllTasks(taskSnapshot)
            .setFocusedDisplayId(focusedDisplayId)
            .setImeSelected(false)
            .setNotificationListenerEnabled(false)
            .setClipboardSeq(0)
            .build()
    }

    override fun setDisplayPolicy(request: SetDisplayPolicy) = displays.applyPolicy(request)

    override suspend fun clearDisplay(request: ClearDisplay) {
        if (displays.readDisplays()[request.displayId] == null) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the display is not known",
                mapOf("display_id" to request.displayId.toString()),
            )
        }
        tasks.clearDisplay(request)
    }

    override fun launchApplication(request: LaunchApplication): LaunchResult =
        launch.launch(request)

    override suspend fun stopApplication(request: StopApplication) = launch.stop(request)

    override fun moveTaskToDisplay(request: MoveTaskToDisplay) {
        val displayId = request.displayId
        if (displayId < 0) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the display ID is not valid",
                mapOf("display_id" to displayId.toString()),
            )
        }
        if (displays.readDisplays()[displayId] == null) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the display is not known",
                mapOf("display_id" to displayId.toString()),
            )
        }
        tasks.moveToDisplay(request.taskId, displayId, request.toBack)
    }

    override fun listTasks(request: ListTasks): TaskList {
        val displayId = if (request.hasDisplayId()) request.displayId else null
        return TaskList.newBuilder().addAllTasks(tasks.list(displayId)).build()
    }

    override fun focusDisplay(displayId: Int) = tasks.focus(displayId)

    override fun queryPackage(request: QueryPackage): PackageInfo = packages.query(request)

    override fun listPackages(request: ListPackages): PackageList = packages.list(request)

    override fun getHealth(): Health = health.getHealth()

    override fun shutdown(requestId: Long, request: Shutdown) = system.shutdown(requestId, request)

    override fun responseSent(requestId: Long) = system.responseSent(requestId)

    override fun responseFailed(requestId: Long) = system.responseFailed(requestId)

    override fun recordFailure(error: io.apkrun.guest.protocol.v1.GuestError) =
        health.recordFailure(error)

    fun systemState(): SystemState =
        SystemState.newBuilder()
            .setBootCompleted(HiddenApi.systemProperty("sys.boot_completed") == "1")
            .setUserUnlocked(HiddenApi.systemProperty("sys.user.0.ce_available") == "true")
            .setAndroidUptimeMs(SystemClock.uptimeMillis())
            .build()
}
