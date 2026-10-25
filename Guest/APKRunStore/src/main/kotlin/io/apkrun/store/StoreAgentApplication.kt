package io.apkrun.store

import android.app.Application
import android.os.Process
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.SocketNameInUse
import io.apkrun.store.store.StoreDaemon

/** Persistent custom-image entry point for the Store Agent. */
class StoreAgentApplication : Application() {
    private var daemon: StoreDaemon? = null

    override fun onCreate() {
        super.onCreate()
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            AgentLog.error("uncaught Store Agent exception", error)
            if (previousHandler != null) {
                previousHandler.uncaughtException(thread, error)
            } else {
                Process.killProcess(Process.myPid())
            }
        }
        val service = StoreDaemon.create(this)
        try {
            service.start()
            daemon = service
        } catch (error: SocketNameInUse) {
            AgentLog.error("another Store Agent is already serving the sockets", error)
            Process.killProcess(Process.myPid())
        }
    }

    override fun onTerminate() {
        daemon?.close()
        super.onTerminate()
    }
}
