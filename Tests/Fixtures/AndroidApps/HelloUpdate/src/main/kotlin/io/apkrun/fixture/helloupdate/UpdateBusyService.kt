package io.apkrun.fixture.helloupdate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.util.Log

/**
 * The `mediaPlayback` foreground service HelloUpdate V1 starts when it is launched with the
 * intent extra `fgs` (test-strategy.md §4.3). It exists so #41's OQ-17 can ask op 110
 * `checkInstallConstraints` whether `GENTLE_UPDATE` reports the package busy while a
 * foreground service runs with no window. It never plays media; it only holds the
 * foreground-service state.
 */
class UpdateBusyService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channel = NotificationChannel(CHANNEL_ID, "HelloUpdate", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("HelloUpdate")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .build()
        startForeground(
            NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        Log.i("APKRUN-FIXTURE", "fgs started")
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private companion object {
        const val CHANNEL_ID = "fgs"
        const val NOTIFICATION_ID = 1
    }
}
