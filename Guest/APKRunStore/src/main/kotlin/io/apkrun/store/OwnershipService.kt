package io.apkrun.store

import android.content.ContentResolver
import android.content.pm.PackageManager
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.runtime.AgentLog

/**
 * The RelinquishUpdateOwnership operation (op 109, guest-protocol.md §11.1): the agent calls
 * `PackageManager.relinquishUpdateOwnership`. The answer is `FAILED_PRECONDITION` when the agent is
 * not the package's update owner, and `NOT_FOUND` when the package is absent.
 */
class OwnershipService(private val packageManager: PackageManager) {
    fun relinquishUpdateOwnership(packageName: String) {
        try {
            packageManager.relinquishUpdateOwnership(packageName)
            AgentLog.info("relinquished update ownership of $packageName")
        } catch (notFound: PackageManager.NameNotFoundException) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the package is not installed",
            )
        } catch (denied: SecurityException) {
            // Not the update owner, or enforcement denied the call (guest-protocol.md §11.1).
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION,
                "io.apkrun.store is not the update owner of $packageName",
            )
        }
    }
}

/**
 * The image's update-ownership enforcement flag, read from `DeviceConfig` and reported in Hello as
 * the `store.ownership.v1` details (guest-components.md §8.2).
 */
class OwnershipEnforcement(private val resolver: ContentResolver) {
    fun updateOwnershipEnforcement(): Boolean {
        // android.provider.DeviceConfig is not in the compileSdk stub; the call is reflective.
        val deviceConfig =
            io.apkrun.guest.runtime.HiddenApi.classOrNull("android.provider.DeviceConfig")
                ?: return true
        return runCatching {
                deviceConfig
                    .getMethod(
                        "getBoolean",
                        String::class.java,
                        String::class.java,
                        Boolean::class.java,
                    )
                    .invoke(null, NAMESPACE, FLAG, true) as Boolean
            }
            .getOrDefault(true)
    }

    companion object {
        const val NAMESPACE = "apkrun"
        const val FLAG = "update_ownership_enforcement"
    }
}
