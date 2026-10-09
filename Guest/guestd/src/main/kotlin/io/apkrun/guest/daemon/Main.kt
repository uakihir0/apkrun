package io.apkrun.guest.daemon

import android.os.Looper
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.SocketNameInUse
import java.io.File
import kotlin.system.exitProcess
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** The agent log of a development agent (guest-components.md §9). */
private const val DEVELOPMENT_LOG_PATH = "/data/local/tmp/apkrun/agent.log"

/** The exit status when another agent already serves the sockets (guest-components.md §3.2). */
private const val EXIT_ALREADY_RUNNING = 3

/**
 * The exit status of an uncaught exception, so that the host sees a clean restart
 * (guest-components.md §3.3).
 */
private const val EXIT_UNCAUGHT = 70

/**
 * The entry point of `apkrun_guestd`. `app_process` runs `io.apkrun.guest.daemon.Main` with the
 * agent's APK on the class path (guest-components.md §3.2). The main looper is prepared first,
 * because the framework's listeners need it.
 */
object Main {
    @JvmStatic
    @Suppress("DEPRECATION") // prepareMainLooper is the call that the framework's own servers use.
    fun main(args: Array<String>) {
        Looper.prepareMainLooper()
        File(DEVELOPMENT_LOG_PATH).parentFile?.mkdirs()
        AgentLog.install(File(DEVELOPMENT_LOG_PATH))
        Thread.setDefaultUncaughtExceptionHandler { _, error ->
            AgentLog.error("uncaught exception", error)
            exitProcess(EXIT_UNCAUGHT)
        }
        val daemon = Daemon(CoroutineScope(SupervisorJob() + Dispatchers.Default))
        try {
            daemon.start()
        } catch (error: SocketNameInUse) {
            AgentLog.error("another agent holds @${error.name}, so this one exits")
            exitProcess(EXIT_ALREADY_RUNNING)
        }
        Looper.loop()
    }
}
