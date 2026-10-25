package io.apkrun.store.store

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.apkrun.guest.protocol.v1.PackageChangeKind
import io.apkrun.guest.protocol.v1.PackageChanged
import io.apkrun.guest.runtime.AgentLog

/** Publishes Android package broadcasts as Store Agent event 102. */
class PackageMonitor(
    private val context: Context,
    private val catalog: StorePackageCatalog,
    private val events: StoreEventSink,
) {
    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val packageName = intent.data?.schemeSpecificPart ?: return
                val replacing = intent.getBooleanExtra(Intent.EXTRA_REPLACING, false)
                onPackageChanged(intent.action.orEmpty(), packageName, replacing)
            }
        }

    fun start() {
        val filter =
            IntentFilter().apply {
                addAction(Intent.ACTION_PACKAGE_ADDED)
                addAction(Intent.ACTION_PACKAGE_REPLACED)
                addAction(Intent.ACTION_PACKAGE_REMOVED)
                addAction(Intent.ACTION_PACKAGE_CHANGED)
                addDataScheme("package")
            }
        context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
    }

    fun close() {
        runCatching { context.unregisterReceiver(receiver) }
    }

    internal fun onPackageChanged(action: String, packageName: String, replacing: Boolean = false) {
        if (!PackageName.isValid(packageName)) return
        val kind =
            when (action) {
                Intent.ACTION_PACKAGE_ADDED ->
                    if (replacing) return else PackageChangeKind.PACKAGE_CHANGE_KIND_ADDED
                Intent.ACTION_PACKAGE_REPLACED -> PackageChangeKind.PACKAGE_CHANGE_KIND_REPLACED
                Intent.ACTION_PACKAGE_REMOVED ->
                    if (replacing) return else PackageChangeKind.PACKAGE_CHANGE_KIND_REMOVED
                Intent.ACTION_PACKAGE_CHANGED -> PackageChangeKind.PACKAGE_CHANGE_KIND_CHANGED
                else -> return
            }
        val versionCode =
            if (kind == PackageChangeKind.PACKAGE_CHANGE_KIND_REMOVED) {
                0L
            } else {
                catalog.find(packageName)?.versionCode ?: 0L
            }
        events.publish(StoreDispatcher.STORE_METADATA_CAPABILITY) { event ->
            event.setStorePackageChanged(
                PackageChanged.newBuilder()
                    .setPackage(packageName)
                    .setKind(kind)
                    .setVersionCode(versionCode.coerceAtLeast(0L))
            )
        }
        AgentLog.info("observed package change ${kind.name}")
    }
}

/** Routes the Android install/uninstall status broadcasts to the active Store Agent. */
class StoreInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val daemon = StoreDaemon.current ?: return
        when (intent.action) {
            ACTION_INSTALL_STATUS -> {
                val installId = intent.getStringExtra(EXTRA_INSTALL_ID) ?: return
                daemon.handleInstallStatus(installId, intent)
            }
            ACTION_UNINSTALL_STATUS -> {
                val operationId = intent.getStringExtra(EXTRA_OPERATION_ID) ?: return
                val status =
                    intent.getIntExtra(
                        android.content.pm.PackageInstaller.EXTRA_STATUS,
                        android.content.pm.PackageInstaller.STATUS_FAILURE,
                    )
                val message =
                    intent
                        .getStringExtra(android.content.pm.PackageInstaller.EXTRA_STATUS_MESSAGE)
                        .orEmpty()
                daemon.completeUninstall(operationId, status, message)
            }
        }
    }

    companion object {
        const val ACTION_INSTALL_STATUS = "io.apkrun.store.action.INSTALL_STATUS"
        const val ACTION_UNINSTALL_STATUS = "io.apkrun.store.action.UNINSTALL_STATUS"
        const val EXTRA_INSTALL_ID = "io.apkrun.store.extra.INSTALL_ID"
        const val EXTRA_OPERATION_ID = "io.apkrun.store.extra.OPERATION_ID"
    }
}
