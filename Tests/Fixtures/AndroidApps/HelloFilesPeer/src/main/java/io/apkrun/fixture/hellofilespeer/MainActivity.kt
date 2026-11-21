package io.apkrun.fixture.hellofilespeer

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
 * The peer fixture of #83 (test-strategy.md §4.2): the HelloFiles picker in a second package that
 * has no shared-folder access. A URI granted to HelloFiles must fail here with SecurityException.
 */
class MainActivity : Activity() {
    private val output = TextView(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        layout.addView(output)
        layout.addView(button("Open file…") { pick(REQUEST_OPEN) })
        setContentView(layout)
        intent?.data?.let { describe(it) }
    }

    private fun pick(request: Int) {
        try {
            startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .setType("*/*")
                    .addCategory(Intent.CATEGORY_OPENABLE),
                request,
            )
        } catch (error: ActivityNotFoundException) {
            toast("no picker")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK) return
        data?.data?.let { describe(it) }
    }

    /** Logs `file <name> <size> <sha256>` or the SecurityException name. */
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
            val digest =
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
            log("file $name $size $digest")
        } catch (error: Exception) {
            log("file error ${error.javaClass.simpleName}")
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
        private const val TAG = "HelloFilesPeer"
        private const val REQUEST_OPEN = 1
    }
}
