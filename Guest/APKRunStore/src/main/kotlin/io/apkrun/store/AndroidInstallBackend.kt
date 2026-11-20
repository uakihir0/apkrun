package io.apkrun.store

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.content.pm.VersionedPackage
import java.io.File
import java.io.OutputStream

/**
 * The [InstallBackend] of the device (guest-components.md §8.2): `PackageInstaller` sessions and
 * the status broadcast that answers `commit`. The broadcast is not exported.
 */
class AndroidInstallBackend(private val context: Context) : InstallBackend {
    override var onFinished: ((androidSessionId: Int, status: Int, message: String) -> Unit)? = null

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(intentContext: Context, intent: Intent) {
                val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
                val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty()
                val uninstallRequest = intent.getIntExtra(EXTRA_UNINSTALL_REQUEST, -1)
                if (uninstallRequest > 0) {
                    pendingUninstalls
                        .remove(uninstallRequest)
                        ?.invoke(
                            UninstallOutcome(
                                status == PackageInstaller.STATUS_SUCCESS,
                                message,
                            )
                        )
                    return
                }
                val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
                if (sessionId >= 0) {
                    onFinished?.invoke(sessionId, status, message)
                }
            }
        }

    private val installer: PackageInstaller
        get() = context.packageManager.packageInstaller

    init {
        context.registerReceiver(
            receiver,
            IntentFilter(ACTION_SESSION_STATUS),
            Context.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun createSession(parameters: SessionParameters): SessionHandle {
        val params =
            PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (parameters.packageName.isNotEmpty()) {
            params.setAppPackageName(parameters.packageName)
        }
        params.setInstallReason(
            if (parameters.installReason > 0) parameters.installReason
            else PackageManager.INSTALL_REASON_USER
        )
        params.setPackageSource(
            if (parameters.packageSource > 0) parameters.packageSource
            else PackageInstaller.PACKAGE_SOURCE_OTHER
        )
        if (parameters.requestUpdateOwnership) {
            params.setRequestUpdateOwnership(true)
        }
        if (parameters.enableRollback) {
            // SessionParams.setEnableRollback is a system API: the privileged app calls it by
            // reflection so a plain compileSdk build links.
            runCatching {
                PackageInstaller.SessionParams::class
                    .java
                    .getMethod("setEnableRollback", Boolean::class.java, Int::class.java)
                    .invoke(params, true, ROLLBACK_DATA_POLICY_RETAIN)
            }
                .onFailure {
                    io.apkrun.guest.runtime.AgentLog.warning("setEnableRollback is not available")
                }
        }

        params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        val sessionId = installer.createSession(params)
        return AndroidSessionHandle(installer.openSession(sessionId), sessionId)
    }

    override fun uninstall(
        packageName: String,
        keepData: Boolean,
        onResult: (UninstallOutcome) -> Unit,
    ) {
        // DELETE_KEEP_DATA is a hidden flag: pm uninstall -k (guest-protocol.md §11).
        val flags = if (keepData) DELETE_KEEP_DATA else 0
        // The status arrives as the same session broadcast: the sender id identifies the call.
        val requestCode = (packageName.hashCode() * 31) + if (keepData) 1 else 0
        pendingUninstalls[requestCode] = onResult
        val intent =
            Intent(ACTION_SESSION_STATUS)
                .setPackage(context.packageName)
                .putExtra(EXTRA_UNINSTALL_REQUEST, requestCode)
        val pending =
            PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
        try {
            installer.uninstall(
                VersionedPackage(packageName, PackageManager.VERSION_CODE_HIGHEST.toLong()),
                flags,
                pending.intentSender,
            )
        } catch (error: Exception) {
            pendingUninstalls.remove(requestCode)
            onResult(UninstallOutcome(false, error.message.orEmpty()))
        }
    }

    private val pendingUninstalls = mutableMapOf<Int, (UninstallOutcome) -> Unit>()

    override fun stagedArchiveInfo(path: File): StagedArchiveInfo? {
        val flags =
            PackageManager.GET_SIGNING_CERTIFICATES.toLong() or
                PackageManager.GET_ACTIVITIES.toLong()
        val info =
            context.packageManager.getPackageArchiveInfo(
                path.absolutePath,
                PackageManager.PackageInfoFlags.of(flags),
            ) ?: return null
        val signing =
            info.signingInfo
                ?: return StagedArchiveInfo(info.packageName, info.longVersionCode, emptyList())
        val digests =
            signing.apkContentsSigners?.map { signer -> signer.toByteArray().sha256() }
                ?: emptyList()
        return StagedArchiveInfo(info.packageName, info.longVersionCode, digests)
    }

    private fun ByteArray.sha256(): ByteArray =
        java.security.MessageDigest.getInstance("SHA-256").digest(this)

    private inner class AndroidSessionHandle(
        private val session: PackageInstaller.Session,
        override val androidSessionId: Int,
    ) : SessionHandle {
        override fun openWrite(name: String, offset: Long, size: Long): OutputStream =
            session.openWrite(name, offset, size)

        override fun commit() {
            val intent =
                Intent(ACTION_SESSION_STATUS)
                    .setPackage(context.packageName)
                    .putExtra(EXTRA_UNINSTALL_REQUEST, 0)
            val pending =
                PendingIntent.getBroadcast(
                    context,
                    androidSessionId,
                    intent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                )
            session.commit(pending.intentSender)
        }

        override fun abandon() {
            runCatching { session.abandon() }
        }
    }

    companion object {
        private const val ACTION_SESSION_STATUS = "io.apkrun.store.INSTALL_STATUS"
        private const val EXTRA_UNINSTALL_REQUEST = "io.apkrun.store.extra.UNINSTALL_REQUEST"

        // PackageManager.DELETE_KEEP_DATA and ROLLBACK_DATA_POLICY_RETAIN are hidden constants.
        private const val DELETE_KEEP_DATA = 0x00000001
        private const val ROLLBACK_DATA_POLICY_RETAIN = 0x00000001
    }
}
