package io.apkrun.guest.daemon

import android.os.SystemClock
import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.ListPackages
import io.apkrun.guest.protocol.v1.PackageInfo
import io.apkrun.guest.protocol.v1.PackageList
import io.apkrun.guest.protocol.v1.QueryPackage
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.Snapshot
import io.apkrun.guest.protocol.v1.StopApplication
import io.apkrun.guest.protocol.v1.SystemState
import io.apkrun.guest.runtime.HiddenApi

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
) : AgentOperations {
    override fun snapshot(): Snapshot =
        Snapshot.newBuilder()
            .setSystem(systemState())
            .addAllDisplays(displays.readDisplays().values)
            .addAllTasks(tasks.list())
            .setFocusedDisplayId(tasks.focusedDisplayId())
            .setImeSelected(false)
            .setNotificationListenerEnabled(false)
            .setClipboardSeq(0)
            .build()

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

    override fun focusDisplay(displayId: Int) = tasks.focus(displayId)

    override fun queryPackage(request: QueryPackage): PackageInfo = packages.query(request)

    override fun listPackages(request: ListPackages): PackageList = packages.list(request)

    private fun systemState(): SystemState =
        SystemState.newBuilder()
            .setBootCompleted(HiddenApi.systemProperty("sys.boot_completed") == "1")
            .setUserUnlocked(HiddenApi.systemProperty("sys.user.0.ce_available") == "true")
            .setAndroidUptimeMs(SystemClock.uptimeMillis())
            .build()
}
