package io.apkrun.guest.runtime

/**
 * Which peers may connect to the agent sockets (guest-components.md §11 pitfalls, guest-protocol.md
 * §14). The host reaches the agent through adbd, which runs as the shell user, or as root after
 * `adb root`. Every other uid is refused. This is the `SO_PEERCRED` check of the abstract sockets.
 */
object PeerCheck {
    /** The shell user, which adbd runs as. */
    const val SHELL_UID = 2000

    /** The root user, which adbd runs as after `adb root`. */
    const val ROOT_UID = 0

    /** Whether a connection from [uid] may use the agent. */
    fun isAllowed(uid: Int): Boolean = uid == SHELL_UID || uid == ROOT_UID
}
