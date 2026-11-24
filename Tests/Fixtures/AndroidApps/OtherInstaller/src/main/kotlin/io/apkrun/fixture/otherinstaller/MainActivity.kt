package io.apkrun.fixture.otherinstaller

import android.app.Activity
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Bundle
import android.util.Log
import android.widget.TextView

/**
 * OtherInstaller, the competing-installer fixture of #40 (test-strategy.md §4.2).
 *
 * On first launch it opens a PackageInstaller session for HelloUpdate V2 from its
 * assets, marks it USER_ACTION_NOT_REQUIRED, and commits it. Whether Android
 * honors that flag is what #40 checks: on the custom image only the update owner
 * may install without user action, so this app must see STATUS_PENDING_USER_ACTION;
 * on stock any installer may. InstallResultReceiver logs `session <status>`.
 */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(TextView(this).apply { text = "OtherInstaller" })
        val seen = getSharedPreferences("otherinstaller", MODE_PRIVATE)
        if (!seen.getBoolean("attempted", false)) {
            seen.edit().putBoolean("attempted", true).apply()
            attemptUpdate()
        }
    }

    private fun attemptUpdate() {
        try {
            val installer = packageManager.packageInstaller
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            ).apply {
                setAppPackageName("io.apkrun.fixture.helloupdate")
                setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
            }
            val sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                assets.open("app.apk").use { input ->
                    session.openWrite("base.apk", 0, -1).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val intent = Intent("io.apkrun.fixture.otherinstaller.INSTALL_RESULT")
                    .setPackage(packageName)
                session.commit(
                    PendingIntent.getBroadcast(
                        this, sessionId, intent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                    ).intentSender
                )
            }
            Log.i("APKRUN-FIXTURE", "session committed")
        } catch (failure: Exception) {
            Log.i("APKRUN-FIXTURE", "session failed ${failure.javaClass.simpleName}")
        }
    }
}
