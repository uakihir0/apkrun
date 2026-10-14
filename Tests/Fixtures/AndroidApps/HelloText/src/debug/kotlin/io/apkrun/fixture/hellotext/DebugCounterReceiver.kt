package io.apkrun.fixture.hellotext

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log

/**
 * Debug build only, registered in src/debug/AndroidManifest.xml (IR-920). It runs
 * [DebugCounterCommands] and [DebugFixtureCommands] for an ADB broadcast and logs the result under
 * the `APKRUN-FIXTURE` tag. The `DETAILS` broadcast opens the Details screen (#025).
 */
class DebugCounterReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (
            intent.action == DebugCounterTouchTraceCommands.ACTION_TRACE_START ||
                intent.action == DebugCounterTouchTraceCommands.ACTION_TRACE_READ
        ) {
            val pending = goAsync()
            CounterOperationQueue.processWide
                .submit {
                    CounterTouchTrace.runDebugCommand(
                        intent.action,
                        SystemClock.elapsedRealtimeNanos(),
                        intent.getStringExtra(DebugCounterTouchTraceCommands.EXTRA_MODE),
                    )
                }
                .whenComplete { traceLines, failure ->
                    try {
                        if (failure != null) {
                            Log.e(
                                MainActivity.LOG_TAG,
                                "debug trace read failed: ${failure.message}",
                            )
                        } else {
                            traceLines?.forEach { Log.i(MainActivity.LOG_TAG, it) }
                        }
                    } finally {
                        pending.finish()
                    }
                }
            return
        }
        val traceLines =
            CounterTouchTrace.runDebugCommand(
                intent.action,
                SystemClock.elapsedRealtimeNanos(),
                intent.getStringExtra(DebugCounterTouchTraceCommands.EXTRA_MODE),
            )
        if (traceLines != null) {
            traceLines.forEach { Log.i(MainActivity.LOG_TAG, it) }
            return
        }
        if (intent.action == DebugFixtureCommands.ACTION_DETAILS) {
            context.startActivity(
                Intent(context, DetailsActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return
        }
        val action = intent.action
        if (
            action == DebugCounterCommands.ACTION_INCREMENT ||
                action == DebugCounterCommands.ACTION_READ
        ) {
            val pending = goAsync()
            CounterOperationQueue.processWide
                .submit {
                    DebugCounterCommands(MainActivity.openCounter(context)).run(action)
                }
                .whenComplete { line, failure ->
                    try {
                        if (failure != null) {
                            Log.e(
                                MainActivity.LOG_TAG,
                                "debug counter command failed: ${failure.message}",
                            )
                        } else if (line != null) {
                            Log.i(MainActivity.LOG_TAG, line)
                        }
                    } finally {
                        pending.finish()
                    }
                }
            return
        }
        val line = DebugFixtureCommands().run(action) ?: return
        Log.i(MainActivity.LOG_TAG, line)
    }
}
