package io.apkrun.guest.daemon

import android.provider.Settings
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.SystemContext
import io.apkrun.guest.runtime.SystemServices

/**
 * The device setup of guest-components.md §3.4 without the IME rows: stay awake, and no keyguard.
 * The agent applies it once per start. Each step is one framework call. A step that fails is
 * logged, and the others still run.
 */
object DeviceSetup {
    /**
     * Applies the steps. The original values are not restored when the agent stops
     * (guest-components.md §3.4).
     */
    fun apply() {
        step("stay awake") {
            val resolver = SystemContext.get().contentResolver
            Settings.Global.putInt(
                resolver,
                Settings.Global.STAY_ON_WHILE_PLUGGED_IN,
                STAY_ON_ALL_POWER_SOURCES,
            )
            Settings.System.putInt(resolver, Settings.System.SCREEN_OFF_TIMEOUT, Int.MAX_VALUE)
        }
        step("no keyguard") {
            SystemServices.lockSettings.call(
                "setBoolean",
                LOCKSCREEN_DISABLED_KEY,
                true,
                SYSTEM_USER_ID,
            )
        }
    }

    private inline fun step(name: String, action: () -> Unit) {
        try {
            action()
            AgentLog.info("device setup: $name applied")
        } catch (error: Exception) {
            AgentLog.warning(
                "device setup: $name failed: ${error.javaClass.simpleName}: ${error.message}"
            )
        }
    }

    /**
     * `BatteryManager.BATTERY_PLUGGED_*` for AC, USB, and wireless: `7`, as `svc power stayon true`
     * sets it.
     */
    private const val STAY_ON_ALL_POWER_SOURCES = 7

    private const val SYSTEM_USER_ID = 0

    /** The lock settings key that `LockPatternUtils.setLockScreenDisabled` writes. */
    private const val LOCKSCREEN_DISABLED_KEY = "lockscreen.disabled"
}
