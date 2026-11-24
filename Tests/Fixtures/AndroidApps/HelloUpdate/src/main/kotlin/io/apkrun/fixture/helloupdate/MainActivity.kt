package io.apkrun.fixture.helloupdate

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.TextView
import java.io.File

/**
 * The main Activity of HelloUpdate, the local update fixture of #38.
 *
 * V1 writes `HELLO` into `files/hello.txt`; V2 must still read it after the update
 * (update-system.md §12). A successful read logs `APKRUN-FIXTURE: data HELLO`, the marker the
 * update T2 tests wait for.
 */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val marker = File(filesDir, "hello.txt")
        val kept = marker.exists() && marker.readText().trim() == "HELLO"
        if (kept) {
            Log.i("APKRUN-FIXTURE", "data HELLO")
        } else {
            marker.writeText("HELLO\n")
            Log.i("APKRUN-FIXTURE", "data written")
        }
        Log.i("APKRUN-FIXTURE", "version ${packageManager.getPackageInfo(packageName, 0).longVersionCode}")
        // test-strategy.md §4.3: launched with the `fgs` extra, V1 holds a
        // mediaPlayback foreground service so OQ-17 can ask op 110 whether
        // GENTLE_UPDATE reports the package busy (#41 step 6).
        if (intent.getBooleanExtra("fgs", false)) {
            startForegroundService(Intent(this, UpdateBusyService::class.java))
        }
        setContentView(TextView(this).apply { text = if (kept) "data HELLO" else "data written" })
    }
}
