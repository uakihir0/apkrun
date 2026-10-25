package io.apkrun.guest.daemon.files

import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.os.ProxyFileDescriptorCallback
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.system.ErrnoException
import android.system.OsConstants
import android.webkit.MimeTypeMap
import io.apkrun.guest.protocol.v1.AccessLevel
import java.io.FileNotFoundException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * SAF view of host-owned Mac folder roots.
 *
 * This provider never opens a host path. Every operation is sent through [MacFilesHostClient], and
 * the host resolves the root and relative path again. The picker may enumerate names; app callers
 * must be present in the access snapshot before metadata or content is returned.
 */
class MacFilesProvider : DocumentsProvider() {
    private var callbackThread: HandlerThread? = null
    private var callbackHandler: Handler? = null

    override fun onCreate(): Boolean {
        if (context == null) return false
        callbackThread =
            HandlerThread("apkrun-mac-files").apply {
                start()
            }
        callbackHandler = Handler(checkNotNull(callbackThread).looper)
        return true
    }

    override fun shutdown() {
        callbackThread?.quitSafely()
        callbackThread = null
        callbackHandler = null
        super.shutdown()
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val access = MacFilesProviderServices.access()
        val configuredRoots = access.roots.values.filter { access.hasReadablePackage(it.rootId) }
        val remoteRoots =
            try {
                val roots = MacFilesProviderServices.hostClient().listRoots(DOCUMENTS_UI_PACKAGE)
                if (
                    roots.size > MAXIMUM_ROOTS || roots.map { it.rootId }.toSet().size != roots.size
                ) {
                    throw IllegalStateException("the host returned an invalid root list")
                }
                roots.associateBy { it.rootId }
            } catch (_: Exception) {
                emptyMap()
            }
        val columns = checkedProjection(projection, ROOT_COLUMNS)
        return MatrixCursor(columns, configuredRoots.size).apply {
            for (configured in configuredRoots) {
                val remote = remoteRoots[configured.rootId]
                if (remote != null && !validRoot(remote)) continue
                val available = remote?.available == true
                val flags =
                    Root.FLAG_LOCAL_ONLY or
                        Root.FLAG_SUPPORTS_IS_CHILD or
                        if (access.hasWritablePackage(configured.rootId)) {
                            Root.FLAG_SUPPORTS_CREATE
                        } else {
                            0
                        }
                addRow(
                    columns
                        .map { column ->
                            when (column) {
                                Root.COLUMN_ROOT_ID -> configured.rootId
                                Root.COLUMN_DOCUMENT_ID -> documentId(configured.rootId, "")
                                Root.COLUMN_TITLE -> remote?.title ?: configured.title
                                Root.COLUMN_MIME_TYPES -> ALL_MIME_TYPES
                                Root.COLUMN_FLAGS -> flags
                                Root.COLUMN_AVAILABLE_BYTES ->
                                    remote?.bytesFree?.takeIf { it >= 0L && available }
                                Root.COLUMN_SUMMARY ->
                                    when {
                                        !available -> UNAVAILABLE_SUMMARY
                                        !access.hasWritablePackage(configured.rootId) ->
                                            READ_ONLY_SUMMARY
                                        else -> null
                                    }
                                else -> null
                            }
                        }
                        .toTypedArray<Any?>()
                )
            }
        }
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val location = parseDocumentId(documentId)
        val caller = callingPackage()
        requireMetadataAccess(caller, location)
        val document = hostCall {
            MacFilesProviderServices.hostClient()
                .stat(
                    caller,
                    location.rootId,
                    location.path,
                )
        }
        validateDocument(document, location.rootId, expectedPath = location.path)
        val columns = checkedProjection(projection, DOCUMENT_COLUMNS)
        return MatrixCursor(columns, 1).apply {
            addRow(
                documentRow(columns, documentId(location.rootId, document.path), document, caller)
            )
        }
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val parent = parseDocumentId(parentDocumentId)
        val caller = callingPackage()
        requireMetadataAccess(caller, parent)
        val page = hostCall {
            MacFilesProviderServices.hostClient()
                .queryChildren(
                    caller,
                    parent.rootId,
                    parent.path,
                    "",
                )
        }
        if (
            page.entries.size > MAXIMUM_PAGE_ENTRIES ||
                page.nextPageToken.length > MAXIMUM_PAGE_TOKEN_LENGTH
        ) {
            throw FileNotFoundException("the host returned an invalid folder listing")
        }
        val columns = checkedProjection(projection, DOCUMENT_COLUMNS)
        val rows =
            page.entries.mapNotNull { child ->
                if (!validDocument(child, parent.rootId)) return@mapNotNull null
                if (parentPath(child.path) != parent.path) return@mapNotNull null
                if (isHiddenOrPackage(child.name)) return@mapNotNull null
                documentRow(columns, documentId(parent.rootId, child.path), child, caller)
            }
        return MatrixCursor(columns, rows.size).apply {
            rows.forEach(::addRow)
            if (page.nextPageToken.isNotEmpty()) {
                extras =
                    Bundle().apply {
                        putString(EXTRA_NEXT_PAGE_TOKEN, page.nextPageToken)
                    }
            }
        }
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val location = parseDocumentId(documentId)
        if (location.path.isEmpty())
            throw FileNotFoundException("a folder cannot be opened as a file")
        val caller = callingPackage()
        val openMode = parseOpenMode(mode)
        val writes = openMode != AccessLevelForOpen.READ
        requireAppAccess(caller, location.rootId, writes)
        requireUriGrant(caller, location, writes)
        val opened = hostCall {
            MacFilesProviderServices.hostClient()
                .openFile(
                    caller,
                    location.rootId,
                    location.path,
                    openMode,
                )
        }
        if (opened.handle <= 0L || opened.size < 0L) {
            runCatching { MacFilesProviderServices.hostClient().closeFile(opened.handle, false) }
            throw FileNotFoundException("the host returned an invalid file handle")
        }
        val storageManager =
            context?.getSystemService(Context.STORAGE_SERVICE) as? StorageManager
                ?: run {
                    runCatching {
                        MacFilesProviderServices.hostClient().closeFile(opened.handle, false)
                    }
                    throw FileNotFoundException("proxy file descriptors are unavailable")
                }
        val handler = callbackHandler
        if (handler == null) {
            runCatching { MacFilesProviderServices.hostClient().closeFile(opened.handle, false) }
            throw FileNotFoundException("proxy file descriptors are unavailable")
        }
        val callback =
            HostProxyFileDescriptor(
                host = MacFilesProviderServices.hostClient(),
                handle = opened.handle,
                initialSize = opened.size,
                packageName = caller,
                rootId = location.rootId,
                writable = writes,
            )
        return try {
            storageManager.openProxyFileDescriptor(
                ParcelFileDescriptor.parseMode(mode),
                callback,
                handler,
            )
        } catch (_: Exception) {
            callback.close(fsync = false)
            throw FileNotFoundException("the host file could not be opened")
        }
    }

    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String,
    ): String {
        val parent = parseDocumentId(parentDocumentId)
        val caller = callingPackage()
        requireAppAccess(caller, parent.rootId, writable = true)
        requireUriGrant(caller, parent, writable = true)
        if (!validName(displayName) || isHiddenOrPackage(displayName))
            throw IllegalArgumentException("the document name is not valid")
        val isDirectory = mimeType == Document.MIME_TYPE_DIR
        val created = hostCall {
            MacFilesProviderServices.hostClient()
                .createDocument(
                    caller,
                    parent.rootId,
                    parent.path,
                    displayName,
                    isDirectory,
                )
        }
        validateDocument(created, parent.rootId)
        if (
            parentPath(created.path) != parent.path ||
                created.name != lastPathComponent(created.path)
        ) {
            throw FileNotFoundException("the host returned an invalid document")
        }
        notifyDocumentChanged(parent.rootId, parent.path)
        return documentId(parent.rootId, created.path)
    }

    override fun deleteDocument(documentId: String) {
        val location = parseDocumentId(documentId)
        if (location.path.isEmpty()) throw SecurityException("a shared root cannot be removed")
        val caller = callingPackage()
        requireAppAccess(caller, location.rootId, writable = true)
        requireUriGrant(caller, location, writable = true)
        hostCall {
            MacFilesProviderServices.hostClient()
                .deleteDocument(
                    caller,
                    location.rootId,
                    location.path,
                )
        }
        notifyDocumentChanged(location.rootId, parentPath(location.path))
    }

    override fun renameDocument(documentId: String, displayName: String): String {
        val location = parseDocumentId(documentId)
        if (location.path.isEmpty()) throw SecurityException("a shared root cannot be renamed")
        val caller = callingPackage()
        requireAppAccess(caller, location.rootId, writable = true)
        requireUriGrant(caller, location, writable = true)
        if (!validName(displayName) || isHiddenOrPackage(displayName))
            throw IllegalArgumentException("the document name is not valid")
        val renamed = hostCall {
            MacFilesProviderServices.hostClient()
                .renameDocument(
                    caller,
                    location.rootId,
                    location.path,
                    displayName,
                )
        }
        validateDocument(renamed, location.rootId)
        if (parentPath(renamed.path) != parentPath(location.path)) {
            throw FileNotFoundException("the host returned an invalid document")
        }
        notifyDocumentChanged(location.rootId, parentPath(location.path))
        return documentId(location.rootId, renamed.path)
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        val parent = parseDocumentId(parentDocumentId)
        val child = parseDocumentId(documentId)
        if (parent.rootId != child.rootId) return false
        if (parent.path.isEmpty()) return child.path.isNotEmpty()
        return child.path.startsWith("${parent.path}/")
    }

    private fun documentRow(
        columns: Array<String>,
        encodedDocumentId: String,
        document: MacFilesDocument,
        caller: String,
    ): Array<Any?> {
        val writable =
            caller != DOCUMENTS_UI_PACKAGE &&
                MacFilesProviderServices.access()
                    .canWrite(caller, parseDocumentId(encodedDocumentId).rootId)
        val flags =
            when {
                document.isDirectory ->
                    (if (writable) Document.FLAG_DIR_SUPPORTS_CREATE else 0) or
                        (if (writable)
                            Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME
                        else 0)
                writable ->
                    Document.FLAG_SUPPORTS_WRITE or
                        Document.FLAG_SUPPORTS_DELETE or
                        Document.FLAG_SUPPORTS_RENAME
                else -> 0
            }
        val mimeType = documentMimeType(document)
        return columns
            .map { column ->
                when (column) {
                    Document.COLUMN_DOCUMENT_ID -> encodedDocumentId
                    Document.COLUMN_DISPLAY_NAME -> document.name
                    Document.COLUMN_MIME_TYPE -> mimeType
                    Document.COLUMN_FLAGS -> flags
                    Document.COLUMN_SIZE -> if (document.isDirectory) null else document.size
                    Document.COLUMN_LAST_MODIFIED -> document.modifiedAtMillis.takeIf { it > 0L }
                    else -> null
                }
            }
            .toTypedArray()
    }

    private fun requireMetadataAccess(caller: String, location: DocumentLocation) {
        val access = MacFilesProviderServices.access()
        val allowed =
            if (caller == DOCUMENTS_UI_PACKAGE) {
                access.root(location.rootId) != null && access.hasReadablePackage(location.rootId)
            } else {
                access.canRead(caller, location.rootId)
            }
        if (!allowed) throw blocked()
        if (caller != DOCUMENTS_UI_PACKAGE) {
            requireUriGrant(caller, location, writable = false)
        }
    }

    private fun requireAppAccess(caller: String, rootId: String, writable: Boolean) {
        val access = MacFilesProviderServices.access()
        val allowed =
            if (caller == DOCUMENTS_UI_PACKAGE && writable) {
                access.hasWritablePackage(rootId)
            } else if (writable) {
                access.canWrite(caller, rootId)
            } else {
                access.canRead(caller, rootId)
            }
        if (!allowed) throw blocked()
    }

    /**
     * Android's picker grants either an exact document URI or a prefix tree URI to the selected
     * app. Requiring one of those grants prevents an otherwise-authorized app from opening a
     * document ID it learned from another URI. DocumentsUI is the fixed, privileged picker caller;
     * it enumerates metadata and performs user-confirmed create operations.
     */
    private fun requireUriGrant(
        caller: String,
        location: DocumentLocation,
        writable: Boolean,
    ) {
        if (caller == DOCUMENTS_UI_PACKAGE) return
        val currentContext = context ?: throw blocked()
        val permission =
            if (writable) {
                android.content.Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            } else {
                android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
            }
        val documentUri =
            DocumentsContract.buildDocumentUri(
                FILES_AUTHORITY,
                documentId(location.rootId, location.path),
            )
        if (
            currentContext.checkCallingUriPermission(documentUri, permission) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val pathComponents = location.path.split('/').filter { it.isNotEmpty() }
        for (depth in 0..pathComponents.size) {
            val grantedTreePath = pathComponents.take(depth).joinToString("/")
            val treeUri =
                DocumentsContract.buildTreeDocumentUri(
                    FILES_AUTHORITY,
                    documentId(location.rootId, grantedTreePath),
                )
            val treeDocumentUri =
                DocumentsContract.buildDocumentUriUsingTree(
                    treeUri,
                    documentId(location.rootId, location.path),
                )
            if (
                currentContext.checkCallingUriPermission(treeDocumentUri, permission) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
        }
        throw blocked()
    }

    private fun callingPackage(): String =
        try {
            callingPackage
        } catch (_: IllegalStateException) {
            null
        } ?: throw SecurityException("a package identity is required")

    private fun parseOpenMode(mode: String): AccessLevelForOpen =
        when (mode) {
            "r" -> AccessLevelForOpen.READ
            "w" -> AccessLevelForOpen.WRITE
            "wt",
            "rwt" -> AccessLevelForOpen.TRUNCATE
            "rw" -> AccessLevelForOpen.READ_WRITE
            else -> throw FileNotFoundException("the requested open mode is not supported")
        }

    private fun parseDocumentId(value: String): DocumentLocation {
        val separator = value.indexOf(':')
        if (separator <= 0 || separator == value.lastIndex) {
            if (separator > 0 && separator == value.lastIndex) {
                val rootId = value.substring(0, separator)
                if (validRootId(rootId)) return DocumentLocation(rootId, "")
            }
            throw FileNotFoundException("the shared document is unavailable")
        }
        val rootId = value.substring(0, separator)
        val path = value.substring(separator + 1)
        if (!validRootId(rootId) || !validRelativePath(path) || isHiddenOrPackagePath(path)) {
            throw FileNotFoundException("the shared document is unavailable")
        }
        return DocumentLocation(rootId, path)
    }

    private fun <T> hostCall(block: () -> T): T =
        try {
            block()
        } catch (error: SecurityException) {
            throw error
        } catch (_: Exception) {
            throw FileNotFoundException("the shared document is unavailable")
        }

    private fun notifyDocumentChanged(rootId: String, path: String) {
        val uri =
            DocumentsContract.buildDocumentUri(
                FILES_AUTHORITY,
                documentId(rootId, path),
            )
        context?.contentResolver?.notifyChange(uri, null)
    }

    private fun validRoot(remote: MacFilesRoot): Boolean =
        validRootId(remote.rootId) &&
            remote.title.isNotBlank() &&
            remote.title.length <= MAXIMUM_TITLE_LENGTH &&
            remote.access in READ_ACCESS_LEVELS &&
            remote.bytesFree >= 0L

    private fun validateDocument(
        document: MacFilesDocument,
        rootId: String,
        expectedPath: String? = null,
    ) {
        if (
            !validDocument(document, rootId) ||
                (expectedPath != null && document.path != expectedPath) ||
                (document.path.isNotEmpty() && document.name != lastPathComponent(document.path))
        ) {
            throw FileNotFoundException("the host returned an invalid document")
        }
    }

    private fun validDocument(document: MacFilesDocument, rootId: String): Boolean =
        validRootId(rootId) &&
            validRelativePath(document.path) &&
            validName(document.name) &&
            document.size >= 0L &&
            document.modifiedAtMillis >= 0L &&
            document.mimeType.length <= MAXIMUM_MIME_TYPE_LENGTH &&
            (document.path.isNotEmpty() || document.isDirectory) &&
            !isHiddenOrPackage(document.name)

    private fun documentMimeType(document: MacFilesDocument): String {
        if (document.isDirectory) return Document.MIME_TYPE_DIR
        if (document.mimeType.isNotBlank()) return document.mimeType
        val extension = document.name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: DEFAULT_MIME_TYPE
    }

    private fun checkedProjection(
        projection: Array<out String>?,
        supported: Set<String>,
    ): Array<String> {
        val columns = projection?.map { it }?.toTypedArray() ?: supported.toTypedArray()
        if (columns.any { it !in supported } || columns.toSet().size != columns.size) {
            throw IllegalArgumentException("the requested columns are not supported")
        }
        return columns
    }

    private fun blocked() = SecurityException(BLOCKED_MESSAGE)

    private data class DocumentLocation(val rootId: String, val path: String)

    private class HostProxyFileDescriptor(
        private val host: MacFilesHostClient,
        private val handle: Long,
        initialSize: Long,
        private val packageName: String,
        private val rootId: String,
        private val writable: Boolean,
    ) : ProxyFileDescriptorCallback() {
        private val currentSize = AtomicLong(initialSize)
        private val closed = AtomicBoolean(false)
        private val readAhead = ByteArray(MAXIMUM_READ_AHEAD_RANGES * MAXIMUM_HOST_FILE_RANGE_BYTES)
        private var readAheadOffset = -1L
        private var readAheadSize = 0

        override fun onGetSize(): Long = currentSize.get()

        @Synchronized
        override fun onRead(offset: Long, size: Int, data: ByteArray): Int {
            requireAccess(write = false)
            if (
                closed.get() ||
                    offset < 0L ||
                    size < 0 ||
                    size > data.size ||
                    offset > Long.MAX_VALUE - size
            ) {
                throw ioFailure("read")
            }
            if (size == 0 || offset >= currentSize.get()) return 0
            if (
                readAheadOffset < 0L ||
                    offset < readAheadOffset ||
                    offset - readAheadOffset >= readAheadSize
            ) {
                fillReadAhead(offset)
            }
            val cacheOffset = (offset - readAheadOffset).toInt()
            val copied =
                minOf(
                        size.toLong(),
                        (readAheadSize - cacheOffset).toLong(),
                        currentSize.get() - offset,
                    )
                    .toInt()
            if (copied <= 0) return 0
            readAhead.copyInto(
                destination = data,
                destinationOffset = 0,
                startIndex = cacheOffset,
                endIndex = cacheOffset + copied,
            )
            return copied
        }

        @Synchronized
        override fun onWrite(offset: Long, size: Int, data: ByteArray): Int {
            if (
                closed.get() ||
                    !writable ||
                    offset < 0L ||
                    size < 0 ||
                    size > data.size ||
                    offset > Long.MAX_VALUE - size
            ) {
                throw ioFailure("write")
            }
            requireAccess(write = true)
            readAheadSize = 0
            readAheadOffset = -1L
            var written = 0
            while (written < size) {
                val count = minOf(size - written, MAXIMUM_HOST_FILE_RANGE_BYTES)
                val chunk = data.copyOfRange(written, written + count)
                try {
                    host.writeRange(handle, offset + written, chunk)
                } catch (_: Exception) {
                    throw ioFailure("write")
                }
                written += count
            }
            currentSize.getAndUpdate { current -> maxOf(current, offset + written) }
            return written
        }

        override fun onFsync() {
            // Writes are synchronous; the host fsyncs when the descriptor is released.
        }

        override fun onRelease() {
            close(fsync = writable)
        }

        @Synchronized
        fun close(fsync: Boolean) {
            if (closed.compareAndSet(false, true)) {
                readAheadSize = 0
                readAheadOffset = -1L
                runCatching { host.closeFile(handle, fsync) }
            }
        }

        private fun fillReadAhead(offset: Long) {
            val remaining = currentSize.get() - offset
            val requiredRanges =
                (remaining / MAXIMUM_HOST_FILE_RANGE_BYTES +
                        if (remaining % MAXIMUM_HOST_FILE_RANGE_BYTES == 0L) 0 else 1)
                    .coerceIn(1L, MAXIMUM_READ_AHEAD_RANGES.toLong())
                    .toInt()
            val ranges =
                try {
                    host.readRanges(handle, offset, requiredRanges)
                } catch (_: Exception) {
                    throw ioFailure("read")
                }
            if (ranges.size > MAXIMUM_READ_AHEAD_RANGES) throw ioFailure("read")
            var cached = 0
            for (bytes in ranges) {
                if (
                    bytes.size > MAXIMUM_HOST_FILE_RANGE_BYTES ||
                        bytes.size.toLong() > remaining - cached
                ) {
                    throw ioFailure("read")
                }
                bytes.copyInto(readAhead, destinationOffset = cached)
                cached += bytes.size
                if (bytes.size < MAXIMUM_HOST_FILE_RANGE_BYTES) break
            }
            readAheadOffset = offset
            readAheadSize = cached
        }

        private fun requireAccess(write: Boolean) {
            val access = MacFilesProviderServices.access()
            val allowed =
                if (write) {
                    access.canWrite(packageName, rootId)
                } else {
                    access.canRead(packageName, rootId)
                }
            if (!allowed) {
                throw ErrnoException("MacFilesProvider.access", OsConstants.EACCES)
            }
        }

        private fun ioFailure(operation: String) =
            ErrnoException(
                "MacFilesProvider.$operation",
                if (closed.get()) OsConstants.EBADF else OsConstants.EIO,
            )
    }

    private companion object {
        const val FILES_AUTHORITY = MAC_FILES_AUTHORITY
        const val DOCUMENTS_UI_PACKAGE = "com.android.documentsui"
        const val BLOCKED_MESSAGE = "Blocked by APKRun settings"
        const val DEFAULT_MIME_TYPE = "application/octet-stream"
        const val ALL_MIME_TYPES = "*/*"
        const val READ_ONLY_SUMMARY = "Read only"
        const val UNAVAILABLE_SUMMARY = "Unavailable"
        const val EXTRA_NEXT_PAGE_TOKEN = "io.apkrun.guest.macfiles.NEXT_PAGE_TOKEN"
        const val MAXIMUM_PAGE_ENTRIES = 4096
        const val MAXIMUM_PAGE_TOKEN_LENGTH = 1024
        const val MAXIMUM_RANGE_BYTES = 1024 * 1024
        const val MAXIMUM_TITLE_LENGTH = 255
        const val MAXIMUM_MIME_TYPE_LENGTH = 255
        const val MAXIMUM_ROOT_ID_LENGTH = 128
        const val MAXIMUM_PATH_LENGTH = 4096
        const val MAXIMUM_ROOTS = 33
        val READ_ACCESS_LEVELS =
            setOf(AccessLevel.ACCESS_LEVEL_READ_ONLY, AccessLevel.ACCESS_LEVEL_READ_WRITE)
        val ROOT_COLUMNS =
            setOf(
                Root.COLUMN_ROOT_ID,
                Root.COLUMN_DOCUMENT_ID,
                Root.COLUMN_TITLE,
                Root.COLUMN_MIME_TYPES,
                Root.COLUMN_FLAGS,
                Root.COLUMN_AVAILABLE_BYTES,
                Root.COLUMN_SUMMARY,
            )
        val DOCUMENT_COLUMNS =
            setOf(
                Document.COLUMN_DOCUMENT_ID,
                Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE,
                Document.COLUMN_FLAGS,
                Document.COLUMN_SIZE,
                Document.COLUMN_LAST_MODIFIED,
            )

        fun documentId(rootId: String, path: String): String = "$rootId:$path"

        fun validRootId(value: String): Boolean =
            value.isNotBlank() &&
                value.length <= MAXIMUM_ROOT_ID_LENGTH &&
                value.all {
                    it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '-'
                }

        fun validRelativePath(value: String): Boolean =
            value.length <= MAXIMUM_PATH_LENGTH &&
                !value.startsWith('/') &&
                !value.contains('\\') &&
                !value.contains('\u0000') &&
                (value.isEmpty() ||
                    value.split('/').all { it.isNotEmpty() && it != "." && it != ".." })

        fun validName(value: String): Boolean =
            value.isNotEmpty() &&
                value.length <= MAXIMUM_TITLE_LENGTH &&
                value != "." &&
                value != ".." &&
                '/' !in value &&
                '\\' !in value &&
                '\u0000' !in value &&
                !value.startsWith(".")

        fun isHiddenOrPackage(name: String): Boolean =
            name.startsWith(".") ||
                name.endsWith(".app", ignoreCase = true) ||
                name.endsWith(".photoslibrary", ignoreCase = true)

        fun isHiddenOrPackagePath(path: String): Boolean = path.split('/').any(::isHiddenOrPackage)

        fun parentPath(path: String): String =
            path.substringBeforeLast('/', missingDelimiterValue = "")

        fun lastPathComponent(path: String): String = path.substringAfterLast('/')

        private fun ioFailure(operation: String) = ErrnoException(operation, OsConstants.EIO)
    }
}
