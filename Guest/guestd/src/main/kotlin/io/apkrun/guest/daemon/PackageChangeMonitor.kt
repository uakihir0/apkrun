package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.PackageChangeKind
import io.apkrun.guest.protocol.v1.PackageChanged

/** Package broadcast translation for the stock Guest Agent (packages.v1, guest-protocol §8.1). */
class PackageChangeMonitor(
    private val events: EventBus,
    private val versionCode: (String) -> Long?,
) {
    /**
     * Processes one package broadcast. The strings match PackageManager's documented action names;
     * keeping this boundary Android-free makes replacement and removal semantics testable on the
     * host JVM.
     */
    fun onPackageChanged(action: String, packageName: String, replacing: Boolean = false) {
        if (!PackageName.isValid(packageName)) return
        val kind =
            when (action) {
                ACTION_ADDED ->
                    if (replacing) return else PackageChangeKind.PACKAGE_CHANGE_KIND_ADDED
                ACTION_REPLACED -> PackageChangeKind.PACKAGE_CHANGE_KIND_REPLACED
                ACTION_REMOVED ->
                    if (replacing) return else PackageChangeKind.PACKAGE_CHANGE_KIND_REMOVED
                ACTION_CHANGED -> PackageChangeKind.PACKAGE_CHANGE_KIND_CHANGED
                else -> return
            }
        val version =
            if (kind == PackageChangeKind.PACKAGE_CHANGE_KIND_REMOVED) {
                0L
            } else {
                versionCode(packageName) ?: 0L
            }
        events.publish(GuestCapability.PACKAGES) {
            it.setPackageChanged(
                PackageChanged.newBuilder()
                    .setPackage(packageName)
                    .setKind(kind)
                    .setVersionCode(version.coerceAtLeast(0L))
            )
        }
    }

    private companion object {
        const val ACTION_ADDED = "android.intent.action.PACKAGE_ADDED"
        const val ACTION_REPLACED = "android.intent.action.PACKAGE_REPLACED"
        const val ACTION_REMOVED = "android.intent.action.PACKAGE_REMOVED"
        const val ACTION_CHANGED = "android.intent.action.PACKAGE_CHANGED"
    }
}
