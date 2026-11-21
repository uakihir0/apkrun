package io.apkrun.guest.files

import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.os.Binder
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.AccessLevel
import io.apkrun.guest.protocol.v1.DocInfo
import io.apkrun.guest.protocol.v1.HostCloseFile
import io.apkrun.guest.protocol.v1.HostCreateDocument
import io.apkrun.guest.protocol.v1.HostListRoots
import io.apkrun.guest.protocol.v1.HostOpenFile
import io.apkrun.guest.protocol.v1.HostQueryChildren
import io.apkrun.guest.protocol.v1.HostReadRange
import io.apkrun.guest.protocol.v1.HostStat
import io.apkrun.guest.protocol.v1.HostWriteRange
import io.apkrun.guest.protocol.v1.OpenMode
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import java.io.FileNotFoundException
import java.io.IOException

/**
 * The `io.apkrun.guest.macfiles` DocumentsProvider (desktop-integration.md §6.4, guest-protocol.md
 * §12). `com.android.documentsui` and the apps with shared-folder access browse the Mac folders the
 * host pushed with `SetSharedFolderAccess` (op 52); every query becomes a Host* request (ops 60–69)
 * on the bulk channel through [HostFileClient]. Nothing is cached locally: a document the host
 * reports missing is refused with [FileNotFoundException].
 *
 * Document ids encode `<rootId>/<path>` so a picker can hand a picked document back to the provider
 * without state. Write access needs [AccessLevel.ACCESS_LEVEL_READ_WRITE] for the calling package
 * on the root; reads need at least read-only.
 */
internal class MacFilesProvider : DocumentsProvider() {

    private lateinit var contextRef: Context
    private var client: HostFileClient? = null
    private var access: FilesBridge? = null

    override fun onCreate(): Boolean {
        val app = context ?: return false
        contextRef = app
        client = MacFilesBridge.client ?: return false
        access = MacFilesBridge.access ?: return false
        return true
    }

    // ---- roots ----------------------------------------------------------------------

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(rootColumns(projection))
        val caller = callerPackage()
        val list =
            hostCall(
                { it.hostListRoots = HostListRoots.newBuilder().setPackage(caller).build() },
                { it.hostListRoots },
            ) ?: return cursor
        for (info in list.rootsList) {
            val root = access?.roots()?.firstOrNull { it.rootId == info.rootId } ?: continue
            val level =
                if (caller == BROWSER_PACKAGE) {
                    // The picker browses every root's names (§6.4); the root's
                    // own cap still decides whether it offers create.
                    if (root.maxAccess == AccessLevel.ACCESS_LEVEL_READ_WRITE) {
                        AccessLevel.ACCESS_LEVEL_READ_WRITE
                    } else {
                        AccessLevel.ACCESS_LEVEL_READ_ONLY
                    }
                } else {
                    access?.accessFor(root, caller) ?: AccessLevel.ACCESS_LEVEL_UNSPECIFIED
                }
            if (level == AccessLevel.ACCESS_LEVEL_UNSPECIFIED) {
                continue
            }
            val row = cursor.newRow()
            row.add(DocumentsContract.Root.COLUMN_ROOT_ID, root.rootId)
            row.add(DocumentsContract.Root.COLUMN_TITLE, root.title)
            row.add(DocumentsContract.Root.COLUMN_SUMMARY, "APKRun shared folder")
            row.add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, "${root.rootId}/")
            row.add(DocumentsContract.Root.COLUMN_ICON, android.R.drawable.ic_menu_save)
            row.add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, info.bytesFree)
            row.add(
                DocumentsContract.Root.COLUMN_FLAGS,
                if (level == AccessLevel.ACCESS_LEVEL_READ_WRITE && info.available) {
                    DocumentsContract.Root.FLAG_SUPPORTS_CREATE
                } else {
                    0
                },
            )
        }
        return cursor
    }

    // ---- document listing -----------------------------------------------------------

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor = children(parentDocumentId, projection, pageToken = "")

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        queryArgs: Bundle?,
    ): Cursor =
        children(
            parentDocumentId,
            projection,
            pageToken = queryArgs?.getString(EXTRA_PAGE_TOKEN) ?: "",
        )

    private fun children(
        parentDocumentId: String,
        projection: Array<out String>?,
        pageToken: String,
    ): Cursor {
        val caller = callerPackage()
        val (rootId, path) =
            splitDocumentId(parentDocumentId) ?: return MatrixCursor(documentColumns(projection))
        val level = levelFor(caller, rootId)
        val cursor = MatrixCursor(documentColumns(projection))
        val page =
            hostCall(
                {
                    it.hostQueryChildren =
                        HostQueryChildren.newBuilder()
                            .setPackage(caller)
                            .setRootId(rootId)
                            .setPath(path)
                            .setPageToken(pageToken)
                            .build()
                },
                { it.hostQueryChildren },
            ) ?: return cursor
        for (entry in page.entriesList) {
            addDocumentRow(cursor, rootId, entry, level)
        }
        if (page.nextPageToken.isNotEmpty()) {
            cursor.extras =
                Bundle().apply {
                    putString(EXTRA_PAGE_TOKEN, page.nextPageToken)
                }
        }
        return cursor
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val caller = callerPackage()
        val cursor = MatrixCursor(documentColumns(projection))
        val (rootId, path) = splitDocumentId(documentId) ?: return cursor
        if (path.isEmpty()) {
            // The root itself is a directory document.
            val root = access?.roots()?.firstOrNull { it.rootId == rootId } ?: return cursor
            val row = cursor.newRow()
            row.add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, documentId)
            row.add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, root.title)
            row.add(
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.MIME_TYPE_DIR,
            )
            row.add(DocumentsContract.Document.COLUMN_FLAGS, 0)
            row.add(DocumentsContract.Document.COLUMN_SIZE, 0L)
            return cursor
        }
        val info =
            hostCall(
                {
                    it.hostStat =
                        HostStat.newBuilder()
                            .setPackage(caller)
                            .setRootId(rootId)
                            .setPath(path)
                            .build()
                },
                { it.hostStat },
            ) ?: return cursor
        addDocumentRow(cursor, rootId, info, levelFor(caller, rootId))
        return cursor
    }

    /** The caller's level on [rootId]; the picker gets the root's own cap (§6.4). */
    private fun levelFor(caller: String, rootId: String): AccessLevel {
        val root =
            access?.roots()?.firstOrNull { it.rootId == rootId }
                ?: return AccessLevel.ACCESS_LEVEL_UNSPECIFIED
        if (caller == BROWSER_PACKAGE) {
            return root.maxAccess
        }
        return access?.accessFor(root, caller) ?: AccessLevel.ACCESS_LEVEL_UNSPECIFIED
    }

    // ---- creating -------------------------------------------------------------------

    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String,
    ): String {
        val caller = callerPackage()
        val (rootId, parentPath) =
            splitDocumentId(parentDocumentId) ?: throw FileNotFoundException(parentDocumentId)
        val created =
            hostCall(
                {
                    it.hostCreateDocument =
                        HostCreateDocument.newBuilder()
                            .setPackage(caller)
                            .setRootId(rootId)
                            .setParentPath(parentPath)
                            .setName(displayName)
                            .setIsDir(mimeType == DocumentsContract.Document.MIME_TYPE_DIR)
                            .build()
                },
                { it.hostCreateDocument },
            ) ?: throw FileNotFoundException(parentDocumentId)
        return "$rootId/${created.path}"
    }

    // ---- opening --------------------------------------------------------------------

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val caller = callerPackage()
        val (rootId, path) = splitDocumentId(documentId) ?: throw FileNotFoundException(documentId)
        val root =
            access?.roots()?.firstOrNull { it.rootId == rootId }
                ?: throw FileNotFoundException(documentId)
        val level = access?.accessFor(root, caller) ?: AccessLevel.ACCESS_LEVEL_UNSPECIFIED
        val write = mode.contains('w') || mode.contains('t')
        if (
            level == AccessLevel.ACCESS_LEVEL_UNSPECIFIED ||
                (write && level != AccessLevel.ACCESS_LEVEL_READ_WRITE)
        ) {
            throw FileNotFoundException("no access for $caller")
        }
        val opened =
            hostCall(
                {
                    it.hostOpenFile =
                        HostOpenFile.newBuilder()
                            .setPackage(caller)
                            .setRootId(rootId)
                            .setPath(path)
                            .setMode(
                                if (write) OpenMode.OPEN_MODE_WRITE else OpenMode.OPEN_MODE_READ
                            )
                            .build()
                },
                { it.hostOpenFile },
            ) ?: throw FileNotFoundException(documentId)
        return openPipe(opened.handle, opened.size, write, signal)
    }

    /**
     * Reads the whole file and serves it through a pipe; writes stream back on close. A cancelled
     * read stops the pump; the handle is closed in every case.
     */
    private fun openPipe(
        handle: Long,
        size: Long,
        write: Boolean,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val pipe = ParcelFileDescriptor.createReliablePipe()
        val reader = ParcelFileDescriptor.AutoCloseInputStream(pipe[0])
        val writer = ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])
        Thread {
            try {
                if (write) {
                    val bytes = reader.readBytes()
                    reader.close()
                    var offset = 0L
                    var ok = true
                    while (ok && offset < bytes.size) {
                        val end = minOf(offset + CHUNK, bytes.size.toLong())
                        val slice = bytes.copyOfRange(offset.toInt(), end.toInt())
                        ok =
                            hostCall(
                                {
                                    it.hostWriteRange =
                                        HostWriteRange.newBuilder()
                                            .setHandle(handle)
                                            .setOffset(offset)
                                            .setData(ByteString.copyFrom(slice))
                                            .build()
                                },
                                { it.hostWriteRange },
                            ) != null
                        offset = end
                    }
                    hostCall(
                        {
                            it.hostCloseFile =
                                HostCloseFile.newBuilder().setHandle(handle).setFsync(ok).build()
                        },
                        { it.hostCloseFile },
                    )
                    writer.close()
                } else {
                    var offset = 0L
                    while (offset < size) {
                        if (signal?.isCanceled == true) break
                        val page =
                            hostCall(
                                {
                                    it.hostReadRange =
                                        HostReadRange.newBuilder()
                                            .setHandle(handle)
                                            .setOffset(offset)
                                            .setLength(CHUNK.toInt())
                                            .build()
                                },
                                { it.hostReadRange },
                            ) ?: break
                        val data = page.data.toByteArray()
                        if (data.isEmpty()) break
                        writer.write(data)
                        offset += data.size
                    }
                    writer.close()
                    hostCall(
                        {
                            it.hostCloseFile =
                                HostCloseFile.newBuilder().setHandle(handle).setFsync(false).build()
                        },
                        { it.hostCloseFile },
                    )
                }
            } catch (error: IOException) {
                try {
                    writer.close()
                } catch (_: IOException) {}
            }
        }
            .start()
        // The client gets the end for its side of the transfer: the write end
        // when it writes into the pipe, the read end when it reads from it.
        return if (write) pipe[1] else pipe[0]
    }

    private fun <T> hostCall(
        build: (Request.Builder) -> Unit,
        pick: (Response) -> T,
    ): T? {
        val response = client?.call(build) ?: return null
        if (response.hasError()) {
            return null
        }
        return pick(response)
    }

    private fun addDocumentRow(
        cursor: MatrixCursor,
        rootId: String,
        info: DocInfo,
        level: AccessLevel,
    ) {
        val row = cursor.newRow()
        row.add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, "$rootId/${info.path}")
        row.add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, info.name)
        row.add(
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            if (info.isDir) {
                DocumentsContract.Document.MIME_TYPE_DIR
            } else {
                info.mimeType.ifEmpty { "application/octet-stream" }
            },
        )
        row.add(DocumentsContract.Document.COLUMN_SIZE, if (info.isDir) 0L else info.size)
        row.add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, info.mtimeMs)
        // A writable entry advertises it so pickers enable rename, delete, and
        // create-inside (§6.4).
        val writable = level == AccessLevel.ACCESS_LEVEL_READ_WRITE
        row.add(
            DocumentsContract.Document.COLUMN_FLAGS,
            when {
                info.isDir && writable ->
                    DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE or
                        DocumentsContract.Document.FLAG_SUPPORTS_WRITE or
                        DocumentsContract.Document.FLAG_SUPPORTS_RENAME or
                        DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                writable ->
                    DocumentsContract.Document.FLAG_SUPPORTS_WRITE or
                        DocumentsContract.Document.FLAG_SUPPORTS_RENAME or
                        DocumentsContract.Document.FLAG_SUPPORTS_DELETE
                else -> 0
            },
        )
    }

    private fun splitDocumentId(documentId: String): Pair<String, String>? {
        val slash = documentId.indexOf('/')
        if (slash < 0) {
            return null
        }
        return documentId.substring(0, slash) to documentId.substring(slash + 1)
    }

    /** The package of the app asking; a caller we cannot name gets the browse-only name. */
    private fun callerPackage(): String =
        try {
            contextRef.packageManager.getPackagesForUid(Binder.getCallingUid())?.firstOrNull()
                ?: "com.android.documentsui"
        } catch (error: Exception) {
            "com.android.documentsui"
        }

    private fun rootColumns(projection: Array<out String>?): Array<out String> =
        projection
            ?: arrayOf(
                DocumentsContract.Root.COLUMN_ROOT_ID,
                DocumentsContract.Root.COLUMN_TITLE,
                DocumentsContract.Root.COLUMN_SUMMARY,
                DocumentsContract.Root.COLUMN_DOCUMENT_ID,
                DocumentsContract.Root.COLUMN_ICON,
                DocumentsContract.Root.COLUMN_AVAILABLE_BYTES,
                DocumentsContract.Root.COLUMN_FLAGS,
            )

    private fun documentColumns(projection: Array<out String>?): Array<out String> =
        projection
            ?: arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_FLAGS,
            )

    companion object {
        private const val CHUNK = 1L shl 20
        private const val EXTRA_PAGE_TOKEN = "io.apkrun.guest.macfiles.nextPageToken"
        /** The system picker: it browses names only and every content op still needs a package. */
        private const val BROWSER_PACKAGE = "com.android.documentsui"
    }
}

/** Publishes the daemon-side handles so the provider can reach them in-process. */
internal object MacFilesBridge {
    @Volatile var client: HostFileClient? = null
    @Volatile var access: FilesBridge? = null
}
