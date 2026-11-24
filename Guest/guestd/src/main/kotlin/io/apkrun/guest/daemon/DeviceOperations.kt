package io.apkrun.guest.daemon

import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import io.apkrun.guest.files.FilesBridge
import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.ActivateNotification
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.ClipData
import io.apkrun.guest.protocol.v1.CollectDiagnostics
import io.apkrun.guest.protocol.v1.CollectDiagnosticsResult
import io.apkrun.guest.protocol.v1.DismissNotification
import io.apkrun.guest.protocol.v1.ExportStart
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Health
import io.apkrun.guest.protocol.v1.ImportFiles
import io.apkrun.guest.protocol.v1.ImportResult
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.ListPackages
import io.apkrun.guest.protocol.v1.ListTasks
import io.apkrun.guest.protocol.v1.MemoryInfo
import io.apkrun.guest.protocol.v1.MoveTaskToDisplay
import io.apkrun.guest.protocol.v1.PackageInfo
import io.apkrun.guest.protocol.v1.PackageList
import io.apkrun.guest.protocol.v1.QueryPackage
import io.apkrun.guest.protocol.v1.ResolveExport
import io.apkrun.guest.protocol.v1.ResolveUrl
import io.apkrun.guest.protocol.v1.SetClockFormat
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.SetLocale
import io.apkrun.guest.protocol.v1.SetMicrophoneAccess
import io.apkrun.guest.protocol.v1.SetNotificationForwarding
import io.apkrun.guest.protocol.v1.SetSharedFolderAccess
import io.apkrun.guest.protocol.v1.SetTimeZone
import io.apkrun.guest.protocol.v1.SetUrlRedirect
import io.apkrun.guest.protocol.v1.Shutdown
import io.apkrun.guest.protocol.v1.Snapshot
import io.apkrun.guest.protocol.v1.StopApplication
import io.apkrun.guest.protocol.v1.SyncTime
import io.apkrun.guest.protocol.v1.SystemState
import io.apkrun.guest.protocol.v1.TaskList
import io.apkrun.guest.runtime.HiddenApi
import io.apkrun.guest.runtime.ServiceMethodMissing
import io.apkrun.guest.runtime.SystemContext
import io.apkrun.guest.runtime.SystemServiceWrapper
import io.apkrun.guest.runtime.SystemServices
import io.apkrun.guest.url.UrlRedirect

/**
 * The operations of the agent on the device, over the services (guest-components.md §6.1). The
 * snapshot reports what the services know. The notification field keeps its default until #55.
 */
internal class DeviceOperations(
    private val displays: DisplayService,
    private val tasks: TaskService,
    private val launch: LaunchService,
    private val packages: PackageService,
    private val diagnostics: DiagnosticsService,
    private val clipboard: ClipboardBridge,
    private val notifications: NotificationBridge,
    private val urlRedirect: UrlRedirect,
    private val microphone: MicrophoneGate,
    private val files: FilesBridge,
    private val input: InputService,
    private val health: HealthService,
    private val system: SystemOperations,
    private val appProcessMonitoringAvailable: () -> Boolean,
    private val localeTime: LocaleTimeService = LocaleTimeService(),
    private val hasMethod: (SystemServiceWrapper, String) -> Boolean = { wrapper, method ->
        wrapper.supports(method)
    },
) : AgentOperations {
    /** Capabilities whose backing framework APIs resolved on this image. */
    fun supportedCapabilities(): Set<GuestCapability> =
        supportedCapabilities(hasMethod, appProcessMonitoringAvailable)

    /** Hidden API methods absent from the current image, for GetHealth diagnostics. */
    fun missingSystemMethods(): List<String> =
        SystemServices.all.flatMap { wrapper ->
            wrapper.missingMethods.map { method -> "${wrapper.serviceName}.$method" }
        }

    override fun snapshot(): Snapshot {
        val displaySnapshot =
            try {
                displays.readDisplays().values.toList()
            } catch (_: ServiceMethodMissing) {
                emptyList()
            } catch (_: LinkageError) {
                emptyList()
            }
        val taskSnapshot =
            try {
                tasks.list()
            } catch (_: ServiceMethodMissing) {
                emptyList()
            } catch (_: LinkageError) {
                emptyList()
            }
        val focusedDisplayId = taskSnapshot.firstOrNull { it.getVisible() }?.getDisplayId() ?: 0
        return Snapshot.newBuilder()
            .setSystem(systemState())
            .addAllDisplays(displays.readDisplays().values)
            .addAllTasks(tasks.list())
            .setFocusedDisplayId(tasks.focusedDisplayId())
            .setImeSelected(imeSelected())
            .setNotificationListenerEnabled(notifications.listenerEnabled())
            .setClipboardSeq(clipboard.currentSequence())
            .build()
    }

    override fun health(): Health {
        val activityManager =
            SystemContext.get().getSystemService(android.app.ActivityManager::class.java)
        val memoryInfo = android.app.ActivityManager.MemoryInfo()
        activityManager?.getMemoryInfo(memoryInfo)
        return Health.newBuilder()
            .setAgentUptimeMs(SystemClock.elapsedRealtime())
            .setMode(
                if (Process.myUid() == Process.SHELL_UID) {
                    AgentMode.AGENT_MODE_DEVELOPMENT_SHELL
                } else {
                    AgentMode.AGENT_MODE_PRIVILEGED_APP
                }
            )
            .setDisplaysCount(displays.readDisplays().size)
            .setImeSelected(imeSelected())
            .setNotificationListenerEnabled(notifications.listenerEnabled())
            .setAdbEnabled(adbEnabled())
            .setMemory(
                MemoryInfo.newBuilder()
                    .setTotalKb(memoryInfo.totalMem / 1024)
                    .setAvailableKb(memoryInfo.availMem / 1024)
                    .setLowMemory(memoryInfo.lowMemory)
            )
            .setInput(input.counters())
            .build()
    }

    /** Whether ADB is enabled on the device (Health.adb_enabled). */
    private fun adbEnabled(): Boolean =
        Settings.Global.getInt(
            SystemContext.get().contentResolver,
            Settings.Global.ADB_ENABLED,
            0,
        ) == 1

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

    override fun moveTaskToDisplay(request: MoveTaskToDisplay) {
        val displayId = request.displayId
        if (displayId < 0) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the display ID is not valid",
                mapOf("display_id" to displayId.toString()),
            )
        }
        if (displays.readDisplays()[displayId] == null) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the display is not known",
                mapOf("display_id" to displayId.toString()),
            )
        }
        tasks.moveToDisplay(request.taskId, displayId, request.toBack)
    }

    override fun listTasks(request: ListTasks): TaskList {
        val displayId = if (request.hasDisplayId()) request.displayId else null
        return TaskList.newBuilder().addAllTasks(tasks.list(displayId)).build()
    }

    override fun focusDisplay(displayId: Int) = tasks.focus(displayId)

    override fun queryPackage(request: QueryPackage): PackageInfo = packages.query(request)

    override fun listPackages(request: ListPackages): PackageList = packages.list(request)

    override fun setLocale(request: SetLocale) = localeTime.setLocale(request)

    override fun setTimeZone(request: SetTimeZone) = localeTime.setTimeZone(request)

    override fun setClockFormat(request: SetClockFormat) = localeTime.setClockFormat(request)

    override fun syncTime(request: SyncTime) = localeTime.syncTime(request)

    override fun setClipboard(request: ClipData) = clipboard.setClipboard(request)

    override fun activateNotification(request: ActivateNotification) =
        notifications.activate(
            request.key,
            if (request.hasActionIndex()) request.actionIndex else null,
            request.displayId,
        )

    override fun dismissNotification(request: DismissNotification) =
        notifications.dismiss(request.key)

    override fun setNotificationForwarding(request: SetNotificationForwarding) =
        notifications.setForwarding(request)

    override fun setUrlRedirect(request: SetUrlRedirect) = urlRedirect.setRedirect(request)

    override fun setMicrophoneAccess(request: SetMicrophoneAccess) = microphone.setAccess(request)

    override fun resolveUrl(request: ResolveUrl) = urlRedirect.resolve(request)

    override fun collectDiagnostics(request: CollectDiagnostics): CollectDiagnosticsResult =
        diagnostics.collect(request)

    override fun importFiles(request: ImportFiles): ImportResult = files.import(request)

    override fun resolveExport(request: ResolveExport): ExportStart = files.resolveExport(request)

    override fun setSharedFolderAccess(request: SetSharedFolderAccess) =
        files.applySharedAccess(request)

    /** Whether the development IME is the selected input method (input.md §5.6). */
    private fun imeSelected(): Boolean =
        Settings.Secure.getString(
            SystemContext.get().contentResolver,
            Settings.Secure.DEFAULT_INPUT_METHOD,
        ) == IME_COMPONENT

    override fun getHealth(): Health = health.getHealth()

    override fun shutdown(requestId: Long, request: Shutdown) = system.shutdown(requestId, request)

    override fun responseSent(requestId: Long) = system.responseSent(requestId)

    override fun responseFailed(requestId: Long) = system.responseFailed(requestId)

    override fun recordFailure(error: io.apkrun.guest.protocol.v1.GuestError) =
        health.recordFailure(error)

    fun systemState(): SystemState =
        SystemState.newBuilder()
            .setBootCompleted(HiddenApi.systemProperty("sys.boot_completed") == "1")
            .setUserUnlocked(HiddenApi.systemProperty("sys.user.0.ce_available") == "true")
            .setAndroidUptimeMs(SystemClock.uptimeMillis())
            .build()

    companion object {
        /** Capabilities whose backing framework APIs resolved on this image. */
        internal fun supportedCapabilities(
            hasMethod: (SystemServiceWrapper, String) -> Boolean,
            appProcessMonitoringAvailable: () -> Boolean,
        ): Set<GuestCapability> = buildSet {
            add(GuestCapability.CORE)
            if (
                hasMethod(SystemServices.display, "getDisplayIds") &&
                    hasMethod(SystemServices.display, "getDisplayInfo") &&
                    hasMethod(SystemServices.display, "registerCallback") &&
                    hasMethod(SystemServices.window, "setForcedDisplayDensityForUser") &&
                    hasMethod(SystemServices.window, "setDisplayImePolicy")
            ) {
                add(GuestCapability.DISPLAY)
            }
            if (
                hasMethod(SystemServices.activityTask, "getTasks") &&
                    hasMethod(SystemServices.activityTask, "registerTaskStackListener") &&
                    hasMethod(SystemServices.activityTask, "startActivityAsUser") &&
                    hasMethod(SystemServices.activityTask, "moveRootTaskToDisplay") &&
                    hasMethod(SystemServices.activityTask, "removeTask") &&
                    hasMethod(SystemServices.activityTask, "setFocusedTask") &&
                    hasMethod(SystemServices.activity, "forceStopPackage")
            ) {
                add(GuestCapability.LAUNCH)
            }
            if (
                hasMethod(SystemServices.activityTask, "getTasks") &&
                    hasMethod(SystemServices.activityTask, "setFocusedTask") &&
                    hasMethod(SystemServices.input, "injectInputEvent")
            ) {
                add(GuestCapability.INPUT)
            }
            add(GuestCapability.INPUT_ACK_TRACE)
            add(GuestCapability.PACKAGES)
            if (appProcessMonitoringAvailable()) {
                add(GuestCapability.HEALTH)
            }
            if (hasMethod(SystemServices.power, "shutdown")) {
                add(GuestCapability.SYSTEM)
            }
        }

        /** Flat component of the development IME, as `DeviceSetup` selects it. */
        private const val IME_COMPONENT = "io.apkrun.guest/.ime.ApkRunInputMethodService"
    }
}
