package io.apkrun.store

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import io.apkrun.guest.protocol.v1.RollbackResult
import io.apkrun.guest.protocol.v1.RollbackStatus
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The RollbackPackage operation (op 108, guest-protocol.md §11.1): finds the `RollbackManager`
 * entry matching the package and both version codes and calls `commitRollback`. `NOT_AVAILABLE`
 * when no rollback was enabled at install or it expired (package-store.md §7.3).
 *
 * `android.content.rollback` is not in the compile SDK stub, so every access is reflective — as are
 * `TEST_MANAGE_ROLLBACKS` semantics, which OQ-11 tracks for `user` builds.
 */
class RollbackService(private val context: Context) {

    /** One commit's status broadcast, completed when RollbackManager answers. */
    private class PendingCommit {
        val done = CountDownLatch(1)
        var status: Int = STATUS_FAILURE
        var message: String = ""
    }

    private val nextRequest = AtomicInteger(1)
    private val pending = mutableMapOf<Int, PendingCommit>()

    private val receiver =
        object : BroadcastReceiver() {
            override fun onReceive(intentContext: Context, intent: Intent) {
                val requestCode = intent.getIntExtra(EXTRA_ROLLBACK_REQUEST, -1)
                val commit = pending.remove(requestCode) ?: return
                commit.status = intent.getIntExtra(EXTRA_STATUS, STATUS_FAILURE)
                commit.message = intent.getStringExtra(EXTRA_STATUS_MESSAGE).orEmpty()
                commit.done.countDown()
            }
        }

    init {
        context.registerReceiver(
            receiver,
            IntentFilter(ACTION_ROLLBACK_STATUS),
            Context.RECEIVER_NOT_EXPORTED,
        )
    }

    fun rollbackPackage(
        packageName: String,
        fromVersionCode: Long,
        toVersionCode: Long,
    ): RollbackResult {
        val managerClass =
            HiddenApi.classOrNull("android.content.rollback.RollbackManager")
                ?: return failure("this image has no RollbackManager")
        val manager =
            runCatching { context.getSystemService(managerClass) }.getOrNull()
                ?: return failure("this image has no RollbackManager")

        val rollbacks = runCatching {
            managerClass.getMethod("getAvailableRollbacks").invoke(manager) as List<*>
        }
            .getOrElse {
                return failure("getAvailableRollbacks: ${it.message ?: "denied"}")
            }
        val match =
            rollbacks.filterNotNull().firstOrNull { info ->
                packagesOf(info).filterNotNull().any { pkg ->
                    nameOf(pkg) == packageName &&
                        versionOf(pkg, "getVersionRolledBackFrom") == fromVersionCode &&
                        versionOf(pkg, "getVersionRolledBackTo") == toVersionCode
                }
            }
                ?: return RollbackResult.newBuilder()
                    .setStatus(RollbackStatus.ROLLBACK_STATUS_NOT_AVAILABLE)
                    .setMessage("no rollback for $packageName $fromVersionCode->$toVersionCode")
                    .build()

        val requestCode = nextRequest.getAndIncrement()
        val commit = PendingCommit()
        pending[requestCode] = commit
        val intent =
            Intent(ACTION_ROLLBACK_STATUS)
                .setPackage(context.packageName)
                .putExtra(EXTRA_ROLLBACK_REQUEST, requestCode)
        val status =
            PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
            )
        try {
            val rollbackInfoClass =
                HiddenApi.classOrNull("android.content.rollback.RollbackInfo")
                    ?: return failure("this image has no RollbackInfo")
            val rollbackId = rollbackInfoClass.getMethod("getRollbackId").invoke(match) as Int
            // commitRollback(int, ParceledListSlice, PendingIntent): the
            // slice lists the packages whose update caused the rollback.
            val versionedPackageClass =
                HiddenApi.classOrNull("android.content.pm.VersionedPackage")
                    ?: return failure("this image has no VersionedPackage")
            val cause =
                versionedPackageClass
                    .getConstructor(
                        String::class.java,
                        Long::class.javaPrimitiveType,
                    )
                    .newInstance(packageName, fromVersionCode)
            val sliceClass =
                HiddenApi.classOrNull("android.content.pm.ParceledListSlice")
                    ?: return failure("this image has no ParceledListSlice")
            val slice = sliceClass.getConstructor(List::class.java).newInstance(listOf(cause))
            managerClass
                .getMethod(
                    "commitRollback",
                    Int::class.javaPrimitiveType,
                    sliceClass,
                    PendingIntent::class.java,
                )
                .invoke(manager, rollbackId, slice, status)
        } catch (error: Exception) {
            pending.remove(requestCode)
            return failure(error.message ?: "commitRollback denied")
        }

        if (!commit.done.await(STATUS_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)) {
            pending.remove(requestCode)
            return failure("commitRollback timed out")
        }
        if (commit.status != STATUS_SUCCESS) {
            return failure(commit.message.ifEmpty { "commitRollback status ${commit.status}" })
        }

        AgentLog.info("rolled back $packageName to $toVersionCode")
        val installed = runCatching {
            context.packageManager.getPackageInfo(packageName, 0).longVersionCode
        }
            .getOrDefault(toVersionCode)
        return RollbackResult.newBuilder()
            .setStatus(RollbackStatus.ROLLBACK_STATUS_SUCCESS)
            .setInstalledVersionCode(installed)
            .build()
    }

    /** `RollbackInfo.getPackages()`. */
    private fun packagesOf(info: Any): List<*> = runCatching {
        info.javaClass.getMethod("getPackages").invoke(info) as List<*>
    }
        .getOrDefault(emptyList<Any>())

    /** `PackageRollbackInfo.getPackageName()`. */
    private fun nameOf(pkg: Any): String = runCatching {
        pkg.javaClass.getMethod("getPackageName").invoke(pkg) as String
    }
        .getOrDefault("")

    /**
     * `PackageRollbackInfo.getVersionRolledBackFrom/To()` returns a `VersionedPackage`; its
     * `getLongVersionCode()` is the compared value.
     */
    private fun versionOf(pkg: Any, getter: String): Long = runCatching {
        val versioned = pkg.javaClass.getMethod(getter).invoke(pkg)
        versioned.javaClass.getMethod("getLongVersionCode").invoke(versioned) as Long
    }
        .getOrDefault(-1L)

    private fun failure(message: String): RollbackResult =
        RollbackResult.newBuilder()
            .setStatus(RollbackStatus.ROLLBACK_STATUS_FAILURE)
            .setMessage(message)
            .build()

    companion object {
        private const val ACTION_ROLLBACK_STATUS = "io.apkrun.store.ROLLBACK_STATUS"
        private const val EXTRA_ROLLBACK_REQUEST = "rollbackRequest"

        // Hidden constants of android.content.rollback.RollbackManager.
        private const val EXTRA_STATUS = "android.content.rollback.extra.STATUS"
        private const val EXTRA_STATUS_MESSAGE = "android.content.rollback.extra.STATUS_MESSAGE"
        private const val STATUS_SUCCESS = 0
        private const val STATUS_FAILURE = 1
        private const val STATUS_TIMEOUT_MILLIS = 60_000L
    }
}
