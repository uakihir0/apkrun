package io.apkrun.fixture.hellofiles

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.Log
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.security.MessageDigest

/**
 * The files fixture of #83 (test-strategy.md §4.2): accepts ACTION_SEND / ACTION_SEND_MULTIPLE
 * shares, opens the system picker (open document, open tree, create document), and shares a
 * generated file — which the Save to Mac activity answers. Each resolved URI logs `file <name>
 * <size> <sha256>` where size and hash are -1/digest when the provider cannot serve them.
 */
class MainActivity : Activity() {
    private val output = TextView(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        layout.addView(output)
        layout.addView(button("Open file…") { pick(REQUEST_OPEN) })
        layout.addView(button("Open tree…") { pick(REQUEST_TREE) })
        layout.addView(button("Create file…") { pick(REQUEST_CREATE) })
        layout.addView(button("Share generated file") { shareGenerated() })
        setContentView(layout)
        handleShare(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleShare(intent)
    }

    private fun handleShare(intent: Intent?) {
        val uris =
            when (intent?.action) {
                Intent.ACTION_SEND ->
                    listOfNotNull(
                        @Suppress("DEPRECATION") intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    )
                Intent.ACTION_SEND_MULTIPLE ->
                    @Suppress("DEPRECATION")
                    intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
                else -> emptyList()
            }
        for (uri in uris) describe(uri)
    }

    private fun pick(request: Int) {
        val intent =
            when (request) {
                REQUEST_OPEN -> Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*")
                REQUEST_TREE -> Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                else ->
                    Intent(Intent.ACTION_CREATE_DOCUMENT)
                        .setType("text/plain")
                        .putExtra(Intent.EXTRA_TITLE, "hellofiles-generated.txt")
            }
        try {
            startActivityForResult(intent.addCategory(Intent.CATEGORY_OPENABLE), request)
        } catch (error: ActivityNotFoundException) {
            toast("no picker")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK) return
        val uri = data?.data ?: return
        if (requestCode == REQUEST_TREE) {
            contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            log("tree $uri")
        } else {
            describe(uri)
        }
    }

    /** Logs `file <name> <size> <sha256>` for one shared or picked document. */
    private fun describe(uri: Uri) {
        var name = uri.lastPathSegment ?: "unknown"
        var size = -1L
        try {
            contentResolver.query(uri, null, null, null, null)?.use { cursor: Cursor ->
                if (cursor.moveToFirst()) {
                    cursor
                        .getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        .takeIf { it >= 0 }
                        ?.let { name = cursor.getString(it) ?: name }
                    cursor
                        .getColumnIndex(OpenableColumns.SIZE)
                        .takeIf { it >= 0 }
                        ?.let { size = cursor.getLong(it) }
                }
            }
        } catch (error: Exception) {
            log("file error ${error.javaClass.simpleName}")
            return
        }
        val digest =
            try {
                contentResolver.openInputStream(uri).use { stream ->
                    if (stream == null) "null"
                    else {
                        val sha = MessageDigest.getInstance("SHA-256")
                        val buffer = ByteArray(1 shl 20)
                        while (true) {
                            val read = stream.read(buffer)
                            if (read < 0) break
                            sha.update(buffer, 0, read)
                        }
                        sha.digest().joinToString("") { "%02x".format(it) }
                    }
                }
            } catch (error: Exception) {
                "error:${error.javaClass.simpleName}"
            }
        log("file $name $size $digest")
    }

    /** A generated text file offered through ACTION_SEND → Save to Mac. */
    private fun shareGenerated() {
        // Insert into MediaStore.Downloads the way a real app hands out a
        // downloadable file — the fixture set has no androidx FileProvider.
        val values =
            android.content.ContentValues().apply {
                put(android.provider.MediaStore.Downloads.DISPLAY_NAME, "hellofiles-generated.txt")
                put(android.provider.MediaStore.Downloads.MIME_TYPE, "text/plain")
            }
        val uri =
            contentResolver.insert(
                android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                values,
            )
        if (uri == null) {
            toast("no downloads store")
            return
        }
        contentResolver.openOutputStream(uri)?.use {
            it.write("HelloFiles generated ${System.currentTimeMillis()}\n".toByteArray())
        }
        val send =
            Intent(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_STREAM, uri)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            startActivity(send)
        } catch (error: ActivityNotFoundException) {
            toast("no share target")
        }
    }

    private fun button(label: String, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            setOnClickListener { action() }
        }

    private fun log(line: String) {
        output.append(line + "\n")
        Log.i(TAG, line)
    }

    private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_LONG).show()

    companion object {
        private const val TAG = "HelloFiles"
        private const val REQUEST_OPEN = 1
        private const val REQUEST_TREE = 2
        private const val REQUEST_CREATE = 3
    }
}
