package io.apkrun.guest.url

import android.app.Activity
import android.app.ActivityOptions
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import io.apkrun.guest.runtime.AgentLog

/**
 * The browser-role holder of desktop-integration.md §7.1. Android resolves App Links to their
 * verified app first, so only links that would go to a browser arrive here — `VIEW` on `http`,
 * `https`, and `mailto`, and `SENDTO` on `mailto` (guest-components.md §5).
 *
 * The activity holds no UI (`Theme.NoDisplay`): it hands the intent to [UrlRedirect] and finishes.
 * Enabled only by the `PRIVILEGED_APP` agent; the development agent runs as the shell uid and the
 * component stays disabled (guest-components.md §3.2, TODO(#36)).
 */
class UrlRedirectActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val redirect = UrlRedirect.instance
        val viewIntent = intent
        val displayId = display?.displayId ?: 0
        if (redirect == null || viewIntent?.data == null) {
            // Without a daemon bridge the link stays in Android (issue #82:
            // the stock-image agent keeps the handler off).
            viewIntent?.let { openInBrowser(this, it, displayId) }
            finish()
            return
        }
        redirect.onLink(
            viewIntent.dataString ?: "",
            launchedFromPackageSafe() ?: "",
            displayId,
        ) { targetDisplay ->
            openInBrowser(this, viewIntent, targetDisplay)
        }
        finish()
    }

    /**
     * `getLaunchedFromPackage` is a system API; the privileged build resolves it and the
     * development build falls back to the referrer (OpenUrlOnHost.source_package, §7.1).
     */
    private fun launchedFromPackageSafe(): String? =
        runCatching {
            Activity::class.java.getMethod("getLaunchedFromPackage").invoke(this) as? String
        }
            .getOrNull() ?: referrer?.authority

    companion object {
        /**
         * Starts [intent] in the in-Android browser on [displayId]: any installed VIEW handler that
         * is not this activity's component, AOSP `Browser2` being the expected one
         * (desktop-integration.md §7.1). With no other handler the link is dropped.
         */
        fun openInBrowser(context: Context, intent: Intent, displayId: Int) {
            val candidates =
                context.packageManager.queryIntentActivities(
                    Intent(intent).setComponent(null),
                    PackageManager.MATCH_ALL,
                )
            val target = candidates.firstOrNull {
                it.activityInfo.packageName != context.packageName
            }
            if (target == null) {
                AgentLog.warning("no in-Android browser for a kept link; dropping it")
                return
            }
            val forward =
                Intent(intent)
                    .setComponent(
                        ComponentName(target.activityInfo.packageName, target.activityInfo.name)
                    )
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            runCatching {
                context.startActivity(
                    forward,
                    ActivityOptions.makeBasic().setLaunchDisplayId(displayId).toBundle(),
                )
            }
                .onFailure { AgentLog.warning("the in-Android browser did not start") }
        }
    }
}
