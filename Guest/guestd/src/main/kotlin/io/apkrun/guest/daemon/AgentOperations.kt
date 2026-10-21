package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.GuestError
import io.apkrun.guest.protocol.v1.Health
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.ListPackages
import io.apkrun.guest.protocol.v1.ListTasks
import io.apkrun.guest.protocol.v1.MoveTaskToDisplay
import io.apkrun.guest.protocol.v1.PackageInfo
import io.apkrun.guest.protocol.v1.PackageList
import io.apkrun.guest.protocol.v1.QueryPackage
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.Shutdown
import io.apkrun.guest.protocol.v1.Snapshot
import io.apkrun.guest.protocol.v1.StopApplication
import io.apkrun.guest.protocol.v1.TaskList

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

    /** Moves one root task to a display (launch.v1). */
    fun moveTaskToDisplay(request: MoveTaskToDisplay)

    /** Returns tasks on the requested display, or all tasks when no display is supplied. */
    fun listTasks(request: ListTasks): TaskList

    /** Moves the focus to the top task of a display (input.v1). */
    fun focusDisplay(displayId: Int)

    /** Returns package metadata from Android's PackageManager (packages.v1). */
    fun queryPackage(request: QueryPackage): PackageInfo

    /** Lists packages from Android's PackageManager (packages.v1). */
    fun listPackages(request: ListPackages): PackageList

    /** Returns the health snapshot (health.v1). */
    fun getHealth(): Health

    /** Prepares an Android shutdown that runs only after response [requestId] is written. */
    fun shutdown(requestId: Long, request: Shutdown)

    /** Called after the connection has flushed response [requestId]. */
    fun responseSent(requestId: Long) {}

    /** Called when the response for [requestId] could not be written. */
    fun responseFailed(requestId: Long) {}

    /** Records the most recent operation failure for the health snapshot. */
    fun recordFailure(error: GuestError) {}
}
