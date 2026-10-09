package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.Snapshot

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

    /** Launches the package of a request on its display (launch.v1). */
    fun launchApplication(request: LaunchApplication): LaunchResult

    /** Moves the focus to the top task of a display (input.v1). */
    fun focusDisplay(displayId: Int)
}
