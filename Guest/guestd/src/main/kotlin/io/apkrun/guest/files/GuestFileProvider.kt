package io.apkrun.guest.files

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.apkrun.guest.daemon.files.ImportedFileCache
import java.io.FileNotFoundException
import java.util.UUID

/**
 * Read-only, package-scoped URI access to APKRun's private import cache.
 *
 * This provider exists only in the custom image. Android's temporary URI permission grants are
 * still required, and the cache record additionally binds each URI to the requested package.
 */
class GuestFileProvider : ContentProvider() {
    private lateinit var cache: ImportedFileCache

    override fun onCreate(): Boolean {
        val appContext = context?.applicationContext ?: return false
        cache = ImportedFileCache(java.io.File(appContext.cacheDir, CACHE_DIRECTORY))
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        if (selection != null || selectionArgs != null || sortOrder != null) {
            throw IllegalArgumentException("queries are not supported")
        }
        val file = authorizedFile(uri)
        val columns = projection ?: DEFAULT_COLUMNS
        if (columns.any { it !in SUPPORTED_COLUMNS }) {
            throw IllegalArgumentException("the requested column is not supported")
        }
        return MatrixCursor(columns).apply {
            addRow(
                columns.map { column ->
                    when (column) {
                        OpenableColumns.DISPLAY_NAME -> file.name
                        OpenableColumns.SIZE -> file.size
                        android.provider.MediaStore.MediaColumns.MIME_TYPE ->
                            file.mimeType.ifEmpty { DEFAULT_MIME_TYPE }
                        else -> null
                    }
                }
            )
        }
    }

    override fun getType(uri: Uri): String =
        authorizedFile(uri).mimeType.ifEmpty { DEFAULT_MIME_TYPE }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("the shared file is read-only")
        val file = authorizedFile(uri)
        return ParcelFileDescriptor.open(file.file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("the import provider is read-only")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("the import provider is read-only")

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException("the import provider is read-only")

    private fun authorizedFile(uri: Uri): ImportedFileCache.CachedFile {
        if (context?.applicationContext == null) throw SecurityException("provider unavailable")
        if (
            uri.scheme != "content" ||
                uri.authority != FILES_AUTHORITY ||
                uri.query != null ||
                uri.fragment != null ||
                uri.pathSegments.size != 2 ||
                uri.pathSegments[0] != "shared"
        ) {
            throw FileNotFoundException("the shared file is unavailable")
        }
        val storageId = uri.pathSegments[1]
        if (runCatching { UUID.fromString(storageId) }.isFailure) {
            throw FileNotFoundException("the shared file is unavailable")
        }
        val caller =
            try {
                callingPackage
            } catch (_: IllegalStateException) {
                null
            } ?: throw SecurityException("a package identity is required")
        return cache.forProvider(storageId, caller)
            ?: throw SecurityException("the file was not shared with this package")
    }

    private companion object {
        const val FILES_AUTHORITY = "io.apkrun.guest.files"
        const val CACHE_DIRECTORY = "files/import"
        const val DEFAULT_MIME_TYPE = "application/octet-stream"
        val DEFAULT_COLUMNS =
            arrayOf(
                OpenableColumns.DISPLAY_NAME,
                OpenableColumns.SIZE,
                android.provider.MediaStore.MediaColumns.MIME_TYPE,
            )
        val SUPPORTED_COLUMNS = DEFAULT_COLUMNS.toSet()
    }
}
