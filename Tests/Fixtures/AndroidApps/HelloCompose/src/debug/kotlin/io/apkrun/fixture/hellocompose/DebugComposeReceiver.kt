package io.apkrun.fixture.hellocompose

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug build only, registered in src/debug/AndroidManifest.xml (IR-920). It runs [DebugComposeCommands] for an
 * ADB broadcast against the list that is shown, and logs the result under the `APKRUN-FIXTURE` tag.
 */
class DebugComposeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val line = DebugComposeCommands.run(
            action = intent.action,
            first = intent.getIntExtra(DebugComposeCommands.EXTRA_FIRST, -1),
            text = intent.getStringExtra(DebugComposeCommands.EXTRA_TEXT),
            host = MainActivity.debugHost,
        ) ?: return
        Log.i(MainActivity.LOG_TAG, line)
    }
}
