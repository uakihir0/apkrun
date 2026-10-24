package io.apkrun.guest

import android.app.Application
import android.os.Process
import io.apkrun.guest.daemon.GuestAgentRuntime
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.SocketNameInUse

/** Persistent custom-image entry point (guest-components.md §4.1). */
class GuestAgentApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            AgentLog.error("uncaught exception", error)
            if (previousHandler != null) {
                previousHandler.uncaughtException(thread, error)
            } else {
                Process.killProcess(Process.myPid())
            }
        }
        val daemon =
            GuestAgentRuntime.create(
                context = this,
                mode = AgentMode.AGENT_MODE_PRIVILEGED_APP,
            )
        try {
            daemon.start()
        } catch (error: SocketNameInUse) {
            AgentLog.error("another agent is already serving the sockets", error)
            Process.killProcess(Process.myPid())
        }
    }
}
