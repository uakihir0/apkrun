package io.apkrun.guest.daemon

import android.net.LocalSocket
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.SessionManager
import io.apkrun.guest.protocol.v1.ChannelKind
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.AgentSocketServer
import io.apkrun.guest.runtime.SystemContext
import io.apkrun.guest.url.UrlRedirect
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/** The abstract socket of the control channel (guest-components.md §3.2). */
const val CONTROL_SOCKET = "apkrun-guestd-control"

/** The abstract socket of the input channel. */
const val INPUT_SOCKET = "apkrun-guestd-input"

/** The abstract socket of the bulk channel. */
const val BULK_SOCKET = "apkrun-guestd-bulk"

/** The installed package whose cache directory stores inbound transfers. */
private const val GUEST_PACKAGE = "io.apkrun.guest"

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

    /**
     * The `apkrun-input` thread, which injects the input events. It runs at display urgency, so
     * that control work does not delay it (guest-components.md §6.3).
     */
    private val inputThread =
        HandlerThread("apkrun-input", Process.THREAD_PRIORITY_URGENT_DISPLAY).apply { start() }
    private val inputHandler = android.os.Handler(inputThread.looper)
    private val inputPost: (() -> Unit) -> Unit = { work ->
        inputHandler.post {
            try {
                work()
            } catch (error: Exception) {
                AgentLog.error("an input task failed", error)
            }
        }
    }

    internal val events = EventBus()
    /**
     * The capabilities the connections advertise: `url.v1` only where the agent runs inside the app
     * and its UrlRedirectActivity can hold the browser role. The shell-uid development agent keeps
     * the handler off (issue #82).
     */
    internal val implemented: Set<GuestCapability> =
        if (Process.myUid() == Process.SHELL_UID) {
            Connection.IMPLEMENTED - GuestCapability.URL
        } else {
            Connection.IMPLEMENTED
        }
    internal val sessions =
        SessionManager({ SystemClock.elapsedRealtime() }) { token ->
            // Publishing must not kill the control accept path: a settings failure degrades to
            // the IME channel refusing connections, not to the agent dying.
            runCatching { ControlTokenProperty.publish(SystemContext.get(), token) }
                .onFailure { AgentLog.warning("the session token could not be published") }
        }
    private val displays = DisplayService(events, post)
    private val tasks = TaskService(events, post)
    private val launch = LaunchService(tasks, displays) { SystemContext.get() }
    private val packages = PackageService(AndroidPackageCatalog(SystemContext.get().packageManager))
    internal val bulkTransfers = BulkTransfers()
    private val diagnostics = DiagnosticsService(bulkTransfers)
    internal val inboundTransfers = InboundTransfers(transfersDir())
    internal val clipboard =
        ClipboardBridge.create(SystemContext.get(), events, bulkTransfers, inboundTransfers)
    internal val notifications =
        NotificationBridge(events, ApkRunNotificationListener.access()).also {
            ApkRunNotificationListener.bridge = it
        }
    internal val urlRedirect =
        UrlRedirect(
                events,
                uptimeMillis = { SystemClock.elapsedRealtime() },
                roleHeld = { browserRoleHeld() },
                takeRole = { takeBrowserRole() },
                // Kept intents expire on the callbacks thread so a silent host
                // cannot hold the intercepted intent forever (§7.1).
                schedule = { delay, action -> callbackHandler.postDelayed(action, delay) },
            )
            .also {
                // The activity and the daemon share a process in PRIVILEGED_APP mode
                // only; in development the bridge stays unreachable and the activity
                // is disabled (guest-components.md §3.2, TODO(#36)).
                if (Process.myUid() != Process.SHELL_UID) {
                    UrlRedirect.instance = it
                }
            }
    internal val input =
        InputService(
            boundsOf = { displayId ->
                displays.modeOf(displayId)?.let { DisplayBounds(it.widthPx, it.heightPx) }
            },
            injector =
                InputInjector(
                    factory = AndroidMotionEventFactory,
                    sink = AndroidInjectionSink,
                    uptimeMillis = { SystemClock.uptimeMillis() },
                ),
            post = inputPost,
        )
    internal val dispatcher =
        Dispatcher(
            operations =
                DeviceOperations(
                    displays,
                    tasks,
                    launch,
                    packages,
                    diagnostics,
                    clipboard,
                    notifications,
                    urlRedirect,
                ),
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
        displays.addRemovalListener { displayId -> input.displayRemoved(displayId) }
        displays.start()
        tasks.start()
        clipboard.start()
        DeviceSetup.apply()
        sockets.forEach { it.start() }
        AgentLog.info("apkrun_guestd is serving the control, input, and bulk sockets")
    }

    /**
     * The directory inbound transfer files land in. In privileged mode the agent runs inside the
     * `io.apkrun.guest` app, and TransferFileProvider resolves files under this same directory in
     * the app process. The development agent runs as the shell uid (guest-components.md §3.2) and
     * cannot write that private directory — it uses the shell-writable log directory instead; the
     * provider path the URI grant needs is privileged-mode only (guest-components.md §5).
     */
    private fun transfersDir(): java.io.File =
        if (android.os.Process.myUid() == android.os.Process.SHELL_UID) {
            java.io.File("/data/local/tmp/apkrun/transfers")
        } else {
            java.io.File(
                SystemContext.get().createPackageContext(GUEST_PACKAGE, 0).cacheDir,
                "transfers",
            )
        }

    /** Whether the app holds `RoleManager.ROLE_BROWSER` (desktop-integration.md §7.1). */
    private fun browserRoleHeld(): Boolean = runCatching {
        val manager = SystemContext.get().getSystemService(android.app.role.RoleManager::class.java)
        manager?.isRoleHeld(android.app.role.RoleManager.ROLE_BROWSER) == true
    }
        .getOrDefault(false)

    /**
     * Takes the browser role again through the privileged `RoleManager.addRoleHolderAsUser`
     * (guest-components.md §5). The shell uid cannot hold a role, so the development agent does
     * nothing here.
     */
    private fun takeBrowserRole() {
        if (Process.myUid() == Process.SHELL_UID) return
        runCatching {
            val manager =
                SystemContext.get().getSystemService(android.app.role.RoleManager::class.java)
                    ?: return@runCatching
            android.app.role.RoleManager::class
                .java
                .getMethod(
                    "addRoleHolderAsUser",
                    String::class.java,
                    String::class.java,
                    Int::class.javaPrimitiveType,
                    android.os.UserHandle::class.java,
                    java.util.concurrent.Executor::class.java,
                    java.util.function.Consumer::class.java,
                )
                .invoke(
                    manager,
                    android.app.role.RoleManager.ROLE_BROWSER,
                    GUEST_PACKAGE,
                    0,
                    Process.myUserHandle(),
                    java.util.concurrent.Executor { it.run() },
                    java.util.function.Consumer<Boolean> {},
                )
        }
            .onFailure { AgentLog.warning("the browser role could not be taken") }
    }

    private fun serve(socket: LocalSocket, channel: ChannelKind) {
        scope.launch(Dispatchers.IO) { Connection(socket, channel, this@Daemon).run() }
    }
}
