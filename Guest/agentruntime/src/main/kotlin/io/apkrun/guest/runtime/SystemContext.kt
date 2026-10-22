package io.apkrun.guest.runtime

import android.content.Context

/**
 * A `Context` for the public APIs that need one. A privileged APK supplies its application context;
 * `app_process` falls back to `ActivityThread.systemMain().getSystemContext()`. The fallback caller
 * must prepare the main looper first (guest-components.md §3.2).
 */
object SystemContext {
    @Volatile private var applicationContext: Context? = null

    private val context: Context by lazy {
        applicationContext?.let {
            return@lazy it
        }
        val thread = HiddenApi.classOrNull("android.app.ActivityThread")
        val main = checkNotNull(thread) { "android.app.ActivityThread is missing" }
        val systemThread = main.getMethod("systemMain").invoke(null)
        val systemContext = main.getMethod("getSystemContext").invoke(systemThread)
        checkNotNull(systemContext as? Context) { "the system context is not a Context" }
    }

    /**
     * Supplies the app context for the platform-signed custom-image agent. `app_process` callers do
     * not install one and retain the system-context fallback.
     */
    fun install(context: Context) {
        check(applicationContext == null) { "the agent context is already installed" }
        applicationContext = context.applicationContext ?: context
    }

    /** The installed app context, or the system context created on first use by `app_process`. */
    fun get(): Context = applicationContext ?: context
}
