package io.apkrun.guest.files

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast

/**
 * The "Save to Mac" share target (desktop-integration.md §6.2). Any Android app can share a file to
 * it through `ACTION_SEND`/`ACTION_SEND_MULTIPLE`; every shared stream becomes an
 * `export_file_offered` event for the host, which then shows its save panel and answers with
 * `ResolveExport` (op 51). The activity is headless: it registers the offers and finishes.
 *
 * The daemon is a different process from this app, so the offers go through [ExportRelay] — a
 * static holder the daemon-side bridge publishes to when both live in one process (the development
 * image), and the activity falls back to a toast when no daemon is listening (TODO(#36): relay
 * through the privileged-app bridge in PRIVILEGED_APP mode).
 */
class SaveToMacActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = sharedStreams(intent)
        val bridge = ExportRelay.bridge
        if (bridge == null || uris.isEmpty()) {
            if (bridge == null) {
                Toast.makeText(this, "Save to Mac is not available", Toast.LENGTH_SHORT).show()
            }
            finish()
            return
        }
        // The extra wins for the in-app send; `referrer` (android-app://pkg)
        // names the requester when the picker launched us without it.
        val sourcePackage =
            intent.getStringExtra(EXTRA_SOURCE_PACKAGE)
                ?: callingPackage()
                ?: referrer?.takeIf { it.scheme == "android-app" }?.host
                ?: ""
        var offered = 0
        for (uri in uris) {
            try {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            } catch (error: SecurityException) {
                // A transient grant is enough: the daemon reads the stream at once on accept.
            }
            if (bridge.offerExport(uri, sourcePackage, displayIdOf()) != null) {
                offered += 1
            }
        }
        if (offered == 0) {
            Toast.makeText(this, "Nothing could be offered to the Mac", Toast.LENGTH_SHORT).show()
        }
        finish()
    }

    private fun sharedStreams(intent: Intent): List<Uri> {
        val result = ArrayList<Uri>()
        when (intent.action) {
            Intent.ACTION_SEND ->
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { result.add(it) }
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let {
                    result.addAll(it)
                }
        }
        return result
    }

    private fun callingPackage(): String? = callingActivity?.packageName

    private fun displayIdOf(): Int =
        try {
            display?.displayId ?: 0
        } catch (error: Exception) {
            0
        }

    companion object {
        /** The package name the sharing app declares itself with, when it does. */
        const val EXTRA_SOURCE_PACKAGE = "io.apkrun.guest.files.SOURCE_PACKAGE"
    }
}

/** Publishes the daemon-side [FilesBridge] so the share activity can reach it in-process. */
internal object ExportRelay {
    @Volatile var bridge: FilesBridge? = null
}
