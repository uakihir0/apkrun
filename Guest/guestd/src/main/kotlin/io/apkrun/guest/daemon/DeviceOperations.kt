package io.apkrun.guest.daemon

import android.os.SystemClock
import android.provider.Settings
import io.apkrun.guest.files.FilesBridge
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.ActivateNotification
import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.ClipData
import io.apkrun.guest.protocol.v1.CollectDiagnostics
import io.apkrun.guest.protocol.v1.CollectDiagnosticsResult
import io.apkrun.guest.protocol.v1.DismissNotification
import io.apkrun.guest.protocol.v1.ExportStart
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ImportFiles
import io.apkrun.guest.protocol.v1.ImportResult
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.ListPackages
import io.apkrun.guest.protocol.v1.PackageInfo
import io.apkrun.guest.protocol.v1.PackageList
import io.apkrun.guest.protocol.v1.QueryPackage
import io.apkrun.guest.protocol.v1.ResolveExport
import io.apkrun.guest.protocol.v1.ResolveUrl
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.SetNotificationForwarding
import io.apkrun.guest.protocol.v1.SetSharedFolderAccess
import io.apkrun.guest.protocol.v1.SetUrlRedirect
import io.apkrun.guest.protocol.v1.Snapshot
import io.apkrun.guest.protocol.v1.StopApplication
import io.apkrun.guest.protocol.v1.SystemState
import io.apkrun.guest.runtime.HiddenApi
import io.apkrun.guest.runtime.SystemContext
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
    private val files: FilesBridge,
) : AgentOperations {
    override fun snapshot(): Snapshot =
        Snapshot.newBuilder()
            .setSystem(systemState())
            .addAllDisplays(displays.readDisplays().values)
            .addAllTasks(tasks.list())
            .setFocusedDisplayId(tasks.focusedDisplayId())
            .setImeSelected(imeSelected())
            .setNotificationListenerEnabled(notifications.listenerEnabled())
            .setClipboardSeq(clipboard.currentSequence())
            .build()

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

    override fun focusDisplay(displayId: Int) = tasks.focus(displayId)

    override fun queryPackage(request: QueryPackage): PackageInfo = packages.query(request)

    override fun listPackages(request: ListPackages): PackageList = packages.list(request)

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

    private fun systemState(): SystemState =
        SystemState.newBuilder()
            .setBootCompleted(HiddenApi.systemProperty("sys.boot_completed") == "1")
            .setUserUnlocked(HiddenApi.systemProperty("sys.user.0.ce_available") == "true")
            .setAndroidUptimeMs(SystemClock.uptimeMillis())
            .build()

    private companion object {
        /** Flat component of the development IME, as `DeviceSetup` selects it. */
        const val IME_COMPONENT = "io.apkrun.guest/.ime.ApkRunInputMethodService"
    }
}
