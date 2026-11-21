package io.apkrun.fixture.otherinstaller

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log

/**
 * Logs the PackageInstaller session result as `APKRUN-FIXTURE: session <status>`
 * (test-strategy.md §4.2). <status> is the EXTRA_STATUS constant name so the
 * #40 checks can tell STATUS_SUCCESS from STATUS_PENDING_USER_ACTION apart.
 */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
        val name = when (status) {
            PackageInstaller.STATUS_SUCCESS -> "SUCCESS"
            PackageInstaller.STATUS_PENDING_USER_ACTION -> "PENDING_USER_ACTION"
            PackageInstaller.STATUS_FAILURE -> "FAILURE"
            PackageInstaller.STATUS_FAILURE_ABORTED -> "FAILURE_ABORTED"
            PackageInstaller.STATUS_FAILURE_BLOCKED -> "FAILURE_BLOCKED"
            PackageInstaller.STATUS_FAILURE_CONFLICT -> "FAILURE_CONFLICT"
            PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "FAILURE_INCOMPATIBLE"
            PackageInstaller.STATUS_FAILURE_INVALID -> "FAILURE_INVALID"
            PackageInstaller.STATUS_FAILURE_STORAGE -> "FAILURE_STORAGE"
            else -> "STATUS_$status"
        }
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            // Bring the confirmation up the way a real installer would; the
            // #40 owner-less check needs the user-action path exercised.
            intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)?.let {
                it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(it)
            }
        }
        Log.i("APKRUN-FIXTURE", "session $name${if (message.isNotEmpty()) " $message" else ""}")
    }
}
