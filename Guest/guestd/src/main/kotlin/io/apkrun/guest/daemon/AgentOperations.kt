package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.ActivateNotification
import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.ClipData
import io.apkrun.guest.protocol.v1.CollectDiagnostics
import io.apkrun.guest.protocol.v1.CollectDiagnosticsResult
import io.apkrun.guest.protocol.v1.DismissNotification
import io.apkrun.guest.protocol.v1.ExportStart
import io.apkrun.guest.protocol.v1.Health
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
import io.apkrun.guest.protocol.v1.SetClockFormat
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.SetLocale
import io.apkrun.guest.protocol.v1.SetNotificationForwarding
import io.apkrun.guest.protocol.v1.SetSharedFolderAccess
import io.apkrun.guest.protocol.v1.SetTimeZone
import io.apkrun.guest.protocol.v1.SetUrlRedirect
import io.apkrun.guest.protocol.v1.Snapshot
import io.apkrun.guest.protocol.v1.StopApplication
import io.apkrun.guest.protocol.v1.SyncTime

/**
 * The operations of the development agent that the [Dispatcher] calls (guest-protocol.md §7.1). The
 * services implement it on the device. A test implements it with fakes. A failure is thrown as a
 * [GuestFailure], or as the exception of the framework call.
 */
interface AgentOperations {
    /** The state that the host reads after every handshake (guest-protocol.md §7.2). */
    fun snapshot(): Snapshot

    /** The agent health counters of `Health` (guest-protocol.md §7.4). */
    fun health(): Health

    /** Applies the density and the IME policy of a display (display.v1). */
    fun setDisplayPolicy(request: SetDisplayPolicy)

    /** Clears every task from a display and reports when it is empty (display.v1). */
    suspend fun clearDisplay(request: ClearDisplay)

    /** Launches the package of a request on its display (launch.v1). */
    fun launchApplication(request: LaunchApplication): LaunchResult

    /** Stops every task belonging to the package (launch.v1). */
    suspend fun stopApplication(request: StopApplication)

    /** Moves the focus to the top task of a display (input.v1). */
    fun focusDisplay(displayId: Int)

    /** Returns package metadata from Android's PackageManager (packages.v1). */
    fun queryPackage(request: QueryPackage): PackageInfo

    /** Lists packages from Android's PackageManager (packages.v1). */
    fun listPackages(request: ListPackages): PackageList

    /** Applies the host's language preferences (locale.v1). */
    fun setLocale(request: SetLocale)

    /** Applies the host's IANA time zone (locale.v1). */
    fun setTimeZone(request: SetTimeZone)

    /** Applies the host's 12/24-hour clock preference (locale.v1). */
    fun setClockFormat(request: SetClockFormat)

    /** Synchronizes the wall clock when the agent has the privileged time-setting permission. */
    fun syncTime(request: SyncTime)

    /** Applies a host clip to the Android clipboard (clipboard.*, desktop-integration.md §4.2). */
    fun setClipboard(request: ClipData)

    /** Fires a notification's content or action intent on a display (notifications.v1, §5.4). */
    fun activateNotification(request: ActivateNotification)

    /** Dismisses a notification on Android (notifications.v1, §5.4). */
    fun dismissNotification(request: DismissNotification)

    /** Replaces the notification forwarding allowlist (notifications.v1, §5.1). */
    fun setNotificationForwarding(request: SetNotificationForwarding)

    /** Applies the link redirect state (url.v1, desktop-integration.md §7.1). */
    fun setUrlRedirect(request: SetUrlRedirect)

    /** Answers a kept link: `OPEN_IN_GUEST` starts it, the rest finish it (url.v1). */
    fun resolveUrl(request: ResolveUrl)

    /** Collects the requested diagnostics items, each on the bulk channel (diagnostics.v1). */
    fun collectDiagnostics(request: CollectDiagnostics): CollectDiagnosticsResult

    /** Shares host-dropped files into the target package or Downloads (files.v1, §6.1). */
    fun importFiles(request: ImportFiles): ImportResult

    /** Accepts or declines a pending export offer (files.v1, §6.2). */
    fun resolveExport(request: ResolveExport): ExportStart

    /** Replaces the shared-folder roots and per-package access map (files.shared.v1, §6.4). */
    fun setSharedFolderAccess(request: SetSharedFolderAccess)
}
