package io.apkrun.guest.daemon

import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.net.LocalSocket
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.SessionManager
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.protocol.v1.ChannelKind
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.AgentSocketServer
import io.apkrun.guest.runtime.ServiceMethodMissing
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
    internal val hostFileClient = io.apkrun.guest.files.HostFileClient()
    internal val filesBridge =
        io.apkrun.guest.files
            .FilesBridge(
                SystemContext.get(),
                events,
                inboundTransfers,
                bulkTransfers,
            )
            .also {
                // The share activity and the DocumentsProvider reach the bridge in-process only;
                // in development the daemon runs under app_process and they stay unbound
                // (TODO(#36)).
                io.apkrun.guest.files.ExportRelay.bridge = it
                io.apkrun.guest.files.MacFilesBridge.access = it
                io.apkrun.guest.files.MacFilesBridge.client = hostFileClient
            }
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
    internal val microphone =
        MicrophoneGate(
                events,
                AndroidOpsAccess(SystemContext.get()),
                AndroidRecordingAccess(SystemContext.get(), callbackHandler),
                AndroidRecordablePackages(SystemContext.get()),
            )
            .also { gate ->
                gate.start()
                // Newly installed packages keep their default silence until the
                // host's next push (desktop-integration.md §8.2).
                MicrophoneGate.watchPackageAdded(SystemContext.get(), gate)
            }
    private val health =
        HealthService(
            events = events,
            uptimeMillis = { SystemClock.elapsedRealtime() },
            mode = { AgentMode.AGENT_MODE_DEVELOPMENT_SHELL },
            displaysCount = {
                try {
                    displays.readDisplays().size
                } catch (_: ServiceMethodMissing) {
                    0
                } catch (_: LinkageError) {
                    0
                }
            },
            imeSelected = ::isImeSelected,
            notificationListenerEnabled = ::isNotificationListenerEnabled,
            adbEnabled = ::isAdbEnabled,
            memory = ::readMemory,
            inputCounters = { input.counters() },
            openSessions = { sessions.openConnectionCount() },
            registerLowMemoryCallback = ::registerLowMemoryCallback,
            postCallback = post,
            missingMethods = { operations.missingSystemMethods() },
        )
    private val system = SystemOperations()
    private val appProcessMonitor = ActivityControllerMonitor(events, postCallback = post)
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
    private val operations: DeviceOperations =
        DeviceOperations(
            displays,
            tasks,
            launch,
            packages,
            diagnostics,
            clipboard,
            notifications,
            urlRedirect,
            microphone,
            filesBridge,
            input,
            health,
            system,
            appProcessMonitoringAvailable = { appProcessMonitor.available },
        )
    private val systemStateMonitor =
        SystemStateMonitor(events, operations::systemState, ::registerSystemStateReceiver)
    private val packageChangeMonitor = PackageChangeMonitor(events, packages::versionCode)
    internal val dispatcher =
        Dispatcher(
            operations = operations,
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
        health.start()
        appProcessMonitor.start()
        systemStateMonitor.start()
        registerPackageChangeReceiver()
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

    /** Capabilities actually backed by APIs that resolved on this image. */
    internal fun supportedCapabilities() = operations.supportedCapabilities()

    /** Called after a control response has been flushed, so Shutdown cannot beat its Empty. */
    internal fun responseSent(requestId: Long) = operations.responseSent(requestId)

    /** Drops a queued shutdown when the response could not be written. */
    internal fun responseFailed(requestId: Long) = operations.responseFailed(requestId)

    private fun serve(socket: LocalSocket, channel: ChannelKind) {
        scope.launch(Dispatchers.IO) { Connection(socket, channel, this@Daemon).run() }
    }

    private fun readMemory(): GuestMemorySnapshot {
        val context = SystemContext.get()
        val manager =
            checkNotNull(context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager) {
                "ActivityManager is unavailable"
            }
        val info = ActivityManager.MemoryInfo()
        manager.getMemoryInfo(info)
        return GuestMemorySnapshot(
            totalKb = info.totalMem / KIBIBYTE,
            availableKb = info.availMem / KIBIBYTE,
            lowMemory = info.lowMemory,
        )
    }

    private fun isImeSelected(): Boolean =
        Settings.Secure.getString(
                SystemContext.get().contentResolver,
                Settings.Secure.DEFAULT_INPUT_METHOD,
            )
            ?.startsWith(APKRUN_IME_COMPONENT_PREFIX) == true

    private fun isNotificationListenerEnabled(): Boolean =
        Settings.Secure.getString(
                SystemContext.get().contentResolver,
                ENABLED_NOTIFICATION_LISTENERS_SETTING,
            )
            ?.split(':')
            .orEmpty()
            .any { it.startsWith(APKRUN_IME_COMPONENT_PREFIX) }

    private fun isAdbEnabled(): Boolean =
        Settings.Global.getInt(
            SystemContext.get().contentResolver,
            Settings.Global.ADB_ENABLED,
            0,
        ) == 1

    private fun registerLowMemoryCallback(callback: () -> Unit) {
        SystemContext.get()
            .registerComponentCallbacks(
                object : ComponentCallbacks2 {
                    override fun onConfigurationChanged(newConfig: Configuration) = Unit

                    override fun onLowMemory() = callback()

                    override fun onTrimMemory(level: Int) {
                        if (
                            level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW ||
                                level == ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL
                        ) {
                            callback()
                        }
                    }
                }
            )
    }

    private fun registerSystemStateReceiver(onChange: () -> Unit) {
        val filter =
            IntentFilter().apply {
                addAction(Intent.ACTION_BOOT_COMPLETED)
                addAction(Intent.ACTION_USER_UNLOCKED)
            }
        SystemContext.get()
            .registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        post(onChange)
                    }
                },
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
    }

    private fun registerPackageChangeReceiver() {
        val filter =
            IntentFilter().apply {
                addAction(Intent.ACTION_PACKAGE_ADDED)
                addAction(Intent.ACTION_PACKAGE_REPLACED)
                addAction(Intent.ACTION_PACKAGE_REMOVED)
                addAction(Intent.ACTION_PACKAGE_CHANGED)
                addDataScheme("package")
            }
        SystemContext.get()
            .registerReceiver(
                object : BroadcastReceiver() {
                    override fun onReceive(context: Context, intent: Intent) {
                        val packageName = intent.data?.schemeSpecificPart ?: return
                        val action = intent.action.orEmpty()
                        val replacing = intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)
                        post {
                            packageChangeMonitor.onPackageChanged(
                                action = action,
                                packageName = packageName,
                                replacing = replacing,
                            )
                        }
                    }
                },
                filter,
                Context.RECEIVER_NOT_EXPORTED,
            )
    }

    private companion object {
        const val KIBIBYTE = 1024L
        const val APKRUN_IME_COMPONENT_PREFIX = "io.apkrun.guest/"
        const val ENABLED_NOTIFICATION_LISTENERS_SETTING = "enabled_notification_listeners"
    }
}
