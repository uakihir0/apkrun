package io.apkrun.guest.daemon

import android.net.LocalSocket
import android.os.HandlerThread
import android.os.SystemClock
import io.apkrun.guest.protocol.v1.ChannelKind
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.AgentSocketServer
import io.apkrun.guest.runtime.SystemContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** The abstract socket of the control channel (guest-components.md §3.2). */
const val CONTROL_SOCKET = "apkrun-guestd-control"

/** The abstract socket of the input channel. */
const val INPUT_SOCKET = "apkrun-guestd-input"

/** The abstract socket of the bulk channel. */
const val BULK_SOCKET = "apkrun-guestd-bulk"

/**
 * The daemon: the three sockets, the sessions, the dispatcher, and the services
 * (guest-components.md §6.1). It is built once per process. [start] binds the sockets, starts the
 * callbacks, and applies the device setup.
 */
class Daemon(internal val scope: CoroutineScope) {
    private val callbackThread = HandlerThread("apkrun-callbacks").apply { start() }
    private val callbackHandler = android.os.Handler(callbackThread.looper)
    /**
     * Runs a callback's work on the callbacks thread. An exception there is logged and does not end
     * the process, because the framework callbacks are not the place for an error that only one
     * capability has.
     */
    private val post: (() -> Unit) -> Unit = { work ->
        callbackHandler.post {
            try {
                work()
            } catch (error: Exception) {
                AgentLog.error("a framework callback failed", error)
            }
        }
    }

    internal val events = EventBus()
    internal val sessions = SessionManager { SystemClock.elapsedRealtime() }
    private val displays = DisplayService(events, post)
    private val tasks = TaskService(events, post)
    private val launch = LaunchService(tasks, displays) { SystemContext.get() }
    internal val input = InputService { displayId ->
        displays.modeOf(displayId)?.let { DisplayBounds(it.widthPx, it.heightPx) }
    }
    internal val dispatcher =
        Dispatcher(
            operations = DeviceOperations(displays, tasks, launch),
            uptimeMillis = { SystemClock.elapsedRealtime() },
        )

    private val sockets =
        listOf(
            AgentSocketServer(CONTROL_SOCKET) { socket, _ ->
                serve(socket, ChannelKind.CHANNEL_KIND_GUEST_CONTROL)
            },
            AgentSocketServer(INPUT_SOCKET) { socket, _ ->
                serve(socket, ChannelKind.CHANNEL_KIND_GUEST_INPUT)
            },
            AgentSocketServer(BULK_SOCKET) { socket, _ ->
                serve(socket, ChannelKind.CHANNEL_KIND_GUEST_BULK)
            },
        )

    /**
     * Binds the sockets, then starts the listeners and the device setup. The control socket is
     * bound first. A [SocketNameInUse] from it means that another agent runs.
     */
    fun start() {
        sockets.forEach { it.bind() }
        displays.start()
        tasks.start()
        DeviceSetup.apply()
        sockets.forEach { it.start() }
        AgentLog.info("apkrun_guestd is serving the control, input, and bulk sockets")
    }

    private fun serve(socket: LocalSocket, channel: ChannelKind) {
        scope.launch(Dispatchers.IO) { Connection(socket, channel, this@Daemon).run() }
    }
}
