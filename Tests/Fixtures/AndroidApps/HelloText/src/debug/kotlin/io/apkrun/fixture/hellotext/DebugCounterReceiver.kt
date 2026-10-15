package io.apkrun.fixture.hellotext

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug build only, registered in src/debug/AndroidManifest.xml (IR-920). It runs
 * [DebugCounterCommands] and [DebugFixtureCommands] for an ADB broadcast and logs the result under
 * the `APKRUN-FIXTURE` tag. The `DETAILS` broadcast opens the Details screen (#025).
 */
class DebugCounterReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            DebugTouchTraceActions.START -> {
                val capacity = DebugTouchTraceSession.start()
                Log.i(MainActivity.LOG_TAG, "debug touch trace started capacity=$capacity")
                return
            }
            DebugTouchTraceActions.STOP_AND_DRAIN -> {
                val drain = DebugTouchTraceSession.stopAndDrain()
                Log.i(
                    MainActivity.LOG_TAG,
                    "debug touch trace drain records=${drain.records.size} " +
                        "dropped=${drain.droppedRecordCount}",
                )
                drain.records.forEach { record ->
                    Log.i(MainActivity.LOG_TAG, "touch-trace ${record.toLogcatLine()}")
                }
                return
            }
        }
        if (intent.action == DebugFixtureCommands.ACTION_DETAILS) {
            context.startActivity(
                Intent(context, DetailsActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }
        val line =
            DebugCounterCommands(MainActivity.openCounter(context)).run(intent.action)
                ?: DebugFixtureCommands().run(intent.action)
                ?: return
        Log.i(MainActivity.LOG_TAG, line)
    }
}
