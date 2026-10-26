package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.ListPackages
import io.apkrun.guest.protocol.v1.PackageInfo
import io.apkrun.guest.protocol.v1.PackageList
import io.apkrun.guest.protocol.v1.QueryPackage
import io.apkrun.guest.protocol.v1.SetClockFormat
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.SetLocale
import io.apkrun.guest.protocol.v1.SetTimeZone
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
}
