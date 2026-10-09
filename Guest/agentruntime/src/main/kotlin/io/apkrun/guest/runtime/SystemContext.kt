package io.apkrun.guest.runtime

import android.content.Context

/**
 * A `Context` of the system process, for the public APIs that need one (`Settings`,
 * `startActivity`). It comes from `ActivityThread.systemMain().getSystemContext()`, which
 * `app_process` can call. The caller must have prepared the main looper first (guest-components.md
 * §3.2).
 */
object SystemContext {
    private val context: Context by lazy {
        val thread = HiddenApi.classOrNull("android.app.ActivityThread")
        val main = checkNotNull(thread) { "android.app.ActivityThread is missing" }
        val systemThread = main.getMethod("systemMain").invoke(null)
        val systemContext = main.getMethod("getSystemContext").invoke(systemThread)
        checkNotNull(systemContext as? Context) { "the system context is not a Context" }
    }

    /** The system context, created on first use. */
    fun get(): Context = context
}
