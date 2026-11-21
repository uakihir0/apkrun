package io.apkrun.guest.daemon

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * Serves inbound bulk transfer files to Android apps (issue #81, desktop-integration.md §4.4). A
 * clipboard image the host pushed lands under `cacheDir/transfers/`; a clip item references it as
 * `content://io.apkrun.guest.files/transfers/<name>` and the pasting app reads it through the
 * clipboard's URI grant. The provider is not exported: access flows only through that grant.
 * Read-only, and only files the [InboundTransfers] directory already holds are reachable — a
 * `transfers/` path with exactly one further segment, no traversal.
 */
internal class TransferFileProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String {
        resolve(uri) ?: throw FileNotFoundException(uri.toString())
        // Transfers in this directory are clipboard PNGs (guest-protocol.md §10).
        return "image/png"
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r" && mode != "rt") {
            throw FileNotFoundException("the provider is read-only")
        }
        val file = resolve(uri) ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** The transfer file the URI names, or `null` when it points elsewhere or is gone. */
    private fun resolve(uri: Uri): File? {
        if (uri.authority != AUTHORITY) {
            return null
        }
        val segments = uri.pathSegments
        if (segments.size != 2 || segments[0] != "transfers") {
            return null
        }
        val name = segments[1]
        if (
            name.isEmpty() ||
                name == "." ||
                name == ".." ||
                name.contains('/') ||
                name.contains('\\')
        ) {
            return null
        }
        val directory = File(context?.cacheDir ?: return null, "transfers")
        val file = File(directory, name)
        return if (file.isFile) file else null
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        /** The provider authority declared in the manifest. */
        const val AUTHORITY = "io.apkrun.guest.files"

        /** The content URI an app pastes for [file] in the transfers directory. */
        fun uriFor(file: File): Uri = Uri.parse(uriForName(file.name))

        /** The URI text `setClipboard` writes; pure so plain unit tests can run it. */
        fun uriForName(name: String): String = "content://$AUTHORITY/transfers/$name"
    }
}
