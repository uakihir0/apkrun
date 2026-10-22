package io.apkrun.guest.runtime

/**
 * Which peers may connect to the agent sockets (guest-components.md §10.1, guest-protocol.md §14).
 * On the stock image, the host reaches the agent through adbd, which runs as the shell user, or as
 * root after `adb root`. On the custom image, `apkrun_vsockd` connects as `system`; `shell` is
 * accepted only when developer mode is enabled. Every other uid is refused. This is the
 * `SO_PEERCRED` check of the abstract sockets.
 */
enum class PeerPolicy {
    /** Development agent started by adbd on a stock Android image. */
    STOCK_DEVELOPMENT,

    /** Persistent privileged agent packaged in the APKRun product image. */
    CUSTOM_PRODUCT,

    /** Unknown launch modes fail closed. */
    REJECT_ALL,
}

object PeerCheck {
    /** The shell user, which adbd runs as. */
    const val SHELL_UID = 2000

    /** The platform system user, which `apkrun_vsockd` runs as on the custom image. */
    const val SYSTEM_UID = 1000

    /** The root user, which adbd runs as after `adb root`. */
    const val ROOT_UID = 0

    /** Whether a connection from [uid] may use the agent. */
    fun isAllowed(uid: Int, policy: PeerPolicy): Boolean =
        isAllowed(uid, policy, HiddenApi.systemProperty("ro.boot.apkrun.devmode"))

    /** An unknown policy or developer-mode property never grants the shell uid access. */
    internal fun isAllowed(uid: Int, policy: PeerPolicy, developerModeProperty: String?): Boolean =
        when (policy) {
            PeerPolicy.STOCK_DEVELOPMENT ->
                isAllowed(uid, customImage = false, developerMode = false)
            PeerPolicy.CUSTOM_PRODUCT ->
                isAllowed(
                    uid,
                    customImage = true,
                    developerMode = developerModeProperty == "1",
                )
            PeerPolicy.REJECT_ALL -> false
        }

    /**
     * Evaluates the image-specific rule. The arguments are explicit so both policies can be covered
     * by JVM tests without depending on Android system properties.
     */
    internal fun isAllowed(uid: Int, customImage: Boolean, developerMode: Boolean): Boolean =
        if (customImage) {
            uid == SYSTEM_UID || uid == ROOT_UID || (uid == SHELL_UID && developerMode)
        } else {
            uid == SHELL_UID || uid == ROOT_UID
        }
}
