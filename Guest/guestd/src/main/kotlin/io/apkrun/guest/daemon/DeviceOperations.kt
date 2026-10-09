package io.apkrun.guest.daemon

import android.os.SystemClock
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.Snapshot
import io.apkrun.guest.protocol.v1.SystemState
import io.apkrun.guest.runtime.HiddenApi

/**
 * The operations of the agent on the device, over the services (guest-components.md §6.1). The
 * snapshot reports what the services know. The IME, notification, and clipboard fields keep their
 * defaults until #071, #053, and #054.
 */
class DeviceOperations(
    private val displays: DisplayService,
    private val tasks: TaskService,
    private val launch: LaunchService,
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

    override fun launchApplication(request: LaunchApplication): LaunchResult =
        launch.launch(request)

    override fun focusDisplay(displayId: Int) = tasks.focus(displayId)

    private fun systemState(): SystemState =
        SystemState.newBuilder()
            .setBootCompleted(HiddenApi.systemProperty("sys.boot_completed") == "1")
            .setUserUnlocked(HiddenApi.systemProperty("sys.user.0.ce_available") == "true")
            .setAndroidUptimeMs(SystemClock.uptimeMillis())
            .build()
}
