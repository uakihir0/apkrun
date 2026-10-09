package io.apkrun.guest.daemon

import android.os.ResultReceiver
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.lang.reflect.InvocationTargetException

/**
 * The device setup of guest-components.md §3.4 without the IME rows: stay awake, and no keyguard.
 * The agent applies it once per start, and a step that fails is logged while the other steps still
 * run. The original values are not restored when the agent stops (guest-components.md §3.4).
 *
 * The settings provider checks the caller's package, and the keyguard switch needs a permission
 * that the shell uid does not hold. The framework's own command services accept the shell uid for
 * these writes, so each step is one call to the service's shell entry point
 * (`IBinder.shellCommand`). That is the entry that `cmd settings` and `cmd lock_settings` use. The
 * agent starts no process for it.
 */
object DeviceSetup {
    /** Applies the steps. */
    fun apply() {
        step("stay awake") {
            serviceCommand(
                "settings",
                "put",
                "global",
                "stay_on_while_plugged_in",
                "$STAY_ON_ALL_POWER_SOURCES",
            )
            serviceCommand("settings", "put", "system", "screen_off_timeout", "${Int.MAX_VALUE}")
        }
        step("no keyguard") {
            serviceCommand("lock_settings", "set-disabled", "true")
        }
    }

    /** Runs one command of the framework service [service] through its shell entry point. */
    private fun serviceCommand(service: String, vararg arguments: String) {
        val binder = checkNotNull(HiddenApi.serviceBinder(service)) { "$service is not registered" }
        val binderInterface =
            checkNotNull(HiddenApi.classOrNull("android.os.IBinder")) { "IBinder is missing" }
        val shellCallback =
            checkNotNull(HiddenApi.classOrNull("android.os.ShellCallback")) {
                "ShellCallback is missing"
            }
        val method =
            binderInterface.getMethod(
                "shellCommand",
                FileDescriptor::class.java,
                FileDescriptor::class.java,
                FileDescriptor::class.java,
                Array<String>::class.java,
                shellCallback,
                ResultReceiver::class.java,
            )
        // The shell entry point takes real descriptors. A null one is passed on as a bad
        // descriptor.
        val input = FileInputStream("/dev/null")
        val output = FileOutputStream("/dev/null")
        try {
            method.invoke(
                binder,
                input.fd,
                output.fd,
                output.fd,
                arrayOf(*arguments),
                null,
                ResultReceiver(null),
            )
        } catch (error: InvocationTargetException) {
            // The framework's own exception is the cause that the log needs.
            throw checkNotNull(error.targetException) { "the service failed without a cause" }
        } finally {
            input.close()
            output.close()
        }
    }

    /**
     * Runs one step. Any failure, including a framework `Error` from a changed interface, is
     * logged, so that the daemon keeps serving the other capabilities.
     */
    private inline fun step(name: String, action: () -> Unit) {
        try {
            action()
            AgentLog.info("device setup: $name applied")
        } catch (error: Throwable) {
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
}
