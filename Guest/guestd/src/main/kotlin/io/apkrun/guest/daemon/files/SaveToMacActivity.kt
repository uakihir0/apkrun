package io.apkrun.guest.daemon.files

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.view.Gravity
import android.widget.TextView
import android.widget.Toast
import io.apkrun.guest.daemon.PackageName
import java.io.IOException

/**
 * Chooser target that offers Android-shared files to APKRun's Mac wrapper.
 *
 * The host displays one native Save panel per item. Source content is never logged or copied into
 * the agent cache; the open descriptor remains alive only until the host accepts, declines, or the
 * offer expires.
 */
class SaveToMacActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(
            TextView(this).apply {
                text = "Choose a location on your Mac for each file."
                gravity = Gravity.CENTER
                setPadding(32, 32, 32, 32)
            }
        )

        val uris = sharedContentUris(intent)
        if (uris.isEmpty() || uris.size > MAXIMUM_FILES_PER_SHARE) {
            showError()
            finish()
            return
        }
        val sourcePackage = sourcePackage()
        if (sourcePackage == null) {
            showError()
            finish()
            return
        }

        val service = SaveToMacRuntime.service
        if (service == null) {
            showError()
            finish()
            return
        }

        val displayId = display?.displayId ?: 0
        Thread(
                {
                    var failed = false
                    for (uri in uris) {
                        val source = openSource(uri, sourcePackage, displayId)
                        if (source == null) {
                            failed = true
                            continue
                        }
                        val outcome = service.offerAndWait(source)
                        if (outcome == ExportOutcome.FAILED) {
                            failed = true
                            break
                        }
                    }
                    runOnUiThread {
                        if (failed) showError()
                        finish()
                    }
                },
                "apkrun-save-to-mac",
            )
            .start()
    }

    private fun sourcePackage(): String? {
        val referrerPackage =
            (referrer ?: intent.getParcelableExtra(Intent.EXTRA_REFERRER, Uri::class.java))
                ?.takeIf { it.scheme == "android-app" }
                ?.authority
        val referrerName =
            intent
                .getStringExtra(Intent.EXTRA_REFERRER_NAME)
                ?.let(Uri::parse)
                ?.takeIf { it.scheme == "android-app" }
                ?.authority
        val candidates = listOfNotNull(referrerPackage, referrerName, callingPackage)
        return candidates.firstOrNull { candidate ->
            candidate.startsWith("com.android.").not() &&
                PackageName.isValid(candidate) &&
                runCatching { packageManager.getApplicationInfo(candidate, 0) }.isSuccess
        }
    }

    private fun openSource(uri: Uri, sourcePackage: String, displayId: Int): ExportFileSource? {
        var descriptor: ParcelFileDescriptor? = null
        try {
            descriptor = contentResolver.openFileDescriptor(uri, "r") ?: return null
            val querySize =
                query(uri) { cursor ->
                    val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                    if (index >= 0 && !cursor.isNull(index)) cursor.getLong(index) else -1L
                }
            val size = descriptor.statSize.takeIf { it >= 0L } ?: querySize ?: -1L
            if (size !in 0L..MAXIMUM_FILE_BYTES) {
                runCatching { descriptor.close() }
                return null
            }
            val name =
                query(uri) { cursor ->
                        val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (index >= 0 && !cursor.isNull(index)) cursor.getString(index) else null
                    }
                    ?.takeIf(String::isNotBlank)
                    ?: uri.lastPathSegment?.takeIf(String::isNotBlank)
                    ?: "Shared file"
            val mimeType =
                contentResolver.getType(uri)?.takeIf(String::isNotBlank)
                    ?: intent.type?.takeIf(String::isNotBlank)
                    ?: DEFAULT_MIME_TYPE
            return ExportFileSource(
                descriptor = descriptor,
                name = name,
                mimeType = mimeType,
                size = size,
                sourcePackage = sourcePackage,
                displayId = displayId,
            )
        } catch (_: SecurityException) {
            descriptor?.let { runCatching { it.close() } }
            return null
        } catch (_: IOException) {
            descriptor?.let { runCatching { it.close() } }
            return null
        } catch (_: RuntimeException) {
            descriptor?.let { runCatching { it.close() } }
            return null
        }
    }

    private inline fun <T> query(uri: Uri, read: (Cursor) -> T): T? =
        try {
            contentResolver
                .query(
                    uri,
                    arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                    null,
                    null,
                    null,
                )
                ?.use { cursor -> if (cursor.moveToFirst()) read(cursor) else null }
        } catch (_: SecurityException) {
            null
        } catch (_: RuntimeException) {
            null
        }

    private fun showError() {
        Toast.makeText(this, "APKRun couldn't save the file to your Mac.", Toast.LENGTH_LONG).show()
    }

    private companion object {
        const val DEFAULT_MIME_TYPE = "application/octet-stream"
    }
}

/** Returns supported content URIs, rejecting malformed or oversized share requests as a whole. */
internal fun sharedContentUris(intent: Intent): List<Uri> {
    return try {
        val values =
            when (intent.action) {
                Intent.ACTION_SEND ->
                    listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
                Intent.ACTION_SEND_MULTIPLE ->
                    intent
                        .getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                        .orEmpty()
                else -> emptyList()
            }
        val selected =
            if (values.isNotEmpty()) {
                values
            } else {
                buildList {
                    val clip = intent.clipData ?: return@buildList
                    for (index in 0 until clip.itemCount) {
                        clip.getItemAt(index).uri?.let(::add)
                    }
                }
            }
        selected
            .takeIf { items ->
                items.isNotEmpty() &&
                    items.size <= MAXIMUM_FILES_PER_SHARE &&
                    items.all { it.scheme == "content" }
            }
            .orEmpty()
    } catch (_: RuntimeException) {
        emptyList()
    }
}

/** Process-local bridge installed by the privileged Guest Agent daemon. */
internal object SaveToMacRuntime {
    @Volatile var service: ExportFileService? = null
}

private const val MAXIMUM_FILES_PER_SHARE = 20
private const val MAXIMUM_FILE_BYTES = 2L * 1024L * 1024L * 1024L
