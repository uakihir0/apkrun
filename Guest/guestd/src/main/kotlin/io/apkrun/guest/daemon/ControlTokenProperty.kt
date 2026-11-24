package io.apkrun.guest.daemon

import android.content.Context
import android.provider.Settings

/**
 * The session token of the currently open control connection (guest-protocol.md §5.4), published
 * through `Settings.Global` so that the IME service — a different process than the `app_process`
 * daemon — can validate a presented token, as `admitSecondary` does on the daemon's own channels.
 * Global settings are world-readable; the token grants nothing beyond the peer check that the IME
 * socket already applies (input.md §5.6).
 */
object ControlTokenProperty {
    /** The `Settings.Global` key the daemon writes the session token to, as hex. */
    private const val KEY = "apkrun_ime_session_token"

    /**
     * The package whose context may write secure settings: `SettingsProvider` checks the calling
     * package belongs to the calling UID, and shell owns `com.android.shell`. The daemon's own
     * system context is `android`, which is not a shell package and is refused.
     */
    private const val SHELL_PACKAGE = "com.android.shell"

    /** Publishes the token of the opened control session; null clears it. */
    fun publish(context: Context, token: ByteArray?) {
        val shell = context.createPackageContext(SHELL_PACKAGE, 0)
        Settings.Global.putString(shell.contentResolver, KEY, token?.toHex())
    }

    /** Whether [token] is the token of the current control session. */
    fun matches(context: Context, token: ByteArray): Boolean {
        val stored = Settings.Global.getString(context.contentResolver, KEY) ?: return false
        return runCatching { stored.hexToByteArray().contentEquals(token) }.getOrDefault(false)
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private fun String.hexToByteArray(): ByteArray {
        require(length % 2 == 0) { "odd hex length" }
        return ByteArray(length / 2) { substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
}
