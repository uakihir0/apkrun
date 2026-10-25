package io.apkrun.store.store

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.VersionedPackage
import io.apkrun.guest.protocol.v1.InstallRequest
import java.io.OutputStream

/** Narrow seam around PackageInstaller so the Store operation paths can be tested on the host. */
internal interface StorePackageInstaller {
    fun createSession(request: InstallRequest): Int

    fun openSession(sessionId: Int): StoreInstallSession

    fun abandonSession(sessionId: Int)

    fun uninstall(packageName: String, keepData: Boolean, operationId: String)
}

internal interface StoreInstallSession {
    fun openWrite(name: String, size: Long): OutputStream

    fun fsync(output: OutputStream)

    fun commit(installId: String)

    fun abandon()

    fun close()
}

/** Android framework adapter used by the production Store Agent. */
internal class AndroidStorePackageInstaller(private val context: Context) : StorePackageInstaller {
    private val installer = context.packageManager.packageInstaller

    override fun createSession(request: InstallRequest): Int {
        val params =
            PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(request.expectedPackage)
        params.setInstallReason(request.installReason)
        params.setPackageSource(request.packageSource)
        params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        params.setSize(request.artifactsList.sumOf { it.size })
        return installer.createSession(params)
    }

    override fun openSession(sessionId: Int): StoreInstallSession =
        AndroidStoreInstallSession(context, sessionId, installer.openSession(sessionId))

    override fun abandonSession(sessionId: Int) = installer.abandonSession(sessionId)

    override fun uninstall(packageName: String, keepData: Boolean, operationId: String) {
        val callback =
            Intent(context, StoreInstallReceiver::class.java)
                .setAction(StoreInstallReceiver.ACTION_UNINSTALL_STATUS)
                .putExtra(StoreInstallReceiver.EXTRA_OPERATION_ID, operationId)
                .setPackage(context.packageName)
        val statusReceiver =
            PendingIntent.getBroadcast(
                context,
                operationId.hashCode(),
                callback,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
        // PackageInstaller's uninstall overload accepts PackageManager.DELETE_KEEP_DATA (1).
        val flags = if (keepData) DELETE_KEEP_DATA else 0
        installer.uninstall(
            VersionedPackage(packageName, PackageManager.VERSION_CODE_HIGHEST),
            flags,
            statusReceiver.intentSender,
        )
    }

    private companion object {
        const val DELETE_KEEP_DATA = 1
    }
}

private class AndroidStoreInstallSession(
    private val context: Context,
    private val sessionId: Int,
    private val session: PackageInstaller.Session,
) : StoreInstallSession {
    override fun openWrite(name: String, size: Long): OutputStream =
        session.openWrite(name, 0, size)

    override fun fsync(output: OutputStream) = session.fsync(output)

    override fun commit(installId: String) {
        val statusIntent =
            Intent(context, StoreInstallReceiver::class.java)
                .setAction(StoreInstallReceiver.ACTION_INSTALL_STATUS)
                .putExtra(StoreInstallReceiver.EXTRA_INSTALL_ID, installId)
                .setPackage(context.packageName)
        val statusReceiver =
            PendingIntent.getBroadcast(
                context,
                sessionId,
                statusIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
        session.commit(statusReceiver.intentSender)
    }

    override fun abandon() = session.abandon()

    override fun close() = session.close()
}
