package io.apkrun.guest.daemon.files

import io.apkrun.guest.daemon.Connection
import io.apkrun.guest.protocol.v1.GuestError
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.HostCloseFile
import io.apkrun.guest.protocol.v1.HostCreateDocument
import io.apkrun.guest.protocol.v1.HostDeleteDocument
import io.apkrun.guest.protocol.v1.HostListRoots
import io.apkrun.guest.protocol.v1.HostOpenFile
import io.apkrun.guest.protocol.v1.HostQueryChildren
import io.apkrun.guest.protocol.v1.HostReadRange
import io.apkrun.guest.protocol.v1.HostRenameDocument
import io.apkrun.guest.protocol.v1.HostStat
import io.apkrun.guest.protocol.v1.HostWriteRange
import io.apkrun.guest.protocol.v1.OpenMode
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import java.io.FileNotFoundException
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CompletionException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Guest-side implementation of the shared-folder host protocol for one bulk connection.
 *
 * All calls use the connection's multiplexed request/response path. At most four adjacent ranges
 * are sent concurrently by [readRanges], keeping the proxy descriptor responsive without moving
 * file data onto the control channel.
 */
internal class MacFilesBulkHostClient(private val connection: Connection) : MacFilesHostClient {
    override fun listRoots(packageName: String): List<MacFilesRoot> {
        val response =
            call(Response.ResultCase.HOST_LIST_ROOTS) {
                setHostListRoots(HostListRoots.newBuilder().setPackage(packageName))
            }
        return response.hostListRoots.rootsList.map { root ->
            if (root.bytesFree < 0L) throw IOException("the host returned invalid free-space data")
            MacFilesRoot(
                rootId = root.rootId,
                title = root.title,
                access = root.access,
                available = root.available,
                bytesFree = root.bytesFree,
            )
        }
    }

    override fun queryChildren(
        packageName: String,
        rootId: String,
        path: String,
        pageToken: String,
    ): MacFilesPage {
        val response =
            call(Response.ResultCase.HOST_QUERY_CHILDREN) {
                setHostQueryChildren(
                    HostQueryChildren.newBuilder()
                        .setPackage(packageName)
                        .setRootId(rootId)
                        .setPath(path)
                        .setPageToken(pageToken)
                )
            }
        val page = response.hostQueryChildren
        if (page.entriesCount > MAXIMUM_PAGE_ENTRIES) {
            throw IOException("the host returned too many shared-folder entries")
        }
        return MacFilesPage(page.entriesList.map(::document), page.nextPageToken)
    }

    override fun stat(packageName: String, rootId: String, path: String): MacFilesDocument {
        val response =
            call(Response.ResultCase.HOST_STAT) {
                setHostStat(
                    HostStat.newBuilder().setPackage(packageName).setRootId(rootId).setPath(path)
                )
            }
        return document(response.hostStat)
    }

    override fun openFile(
        packageName: String,
        rootId: String,
        path: String,
        mode: AccessLevelForOpen,
    ): MacFilesOpenFile {
        val wireMode =
            when (mode) {
                AccessLevelForOpen.READ -> OpenMode.OPEN_MODE_READ
                AccessLevelForOpen.WRITE -> OpenMode.OPEN_MODE_WRITE
                AccessLevelForOpen.READ_WRITE -> OpenMode.OPEN_MODE_READ_WRITE
                AccessLevelForOpen.TRUNCATE -> OpenMode.OPEN_MODE_TRUNCATE
            }
        val response =
            call(Response.ResultCase.HOST_OPEN_FILE) {
                setHostOpenFile(
                    HostOpenFile.newBuilder()
                        .setPackage(packageName)
                        .setRootId(rootId)
                        .setPath(path)
                        .setMode(wireMode)
                )
            }
        val opened = response.hostOpenFile
        if (opened.handle == 0L || opened.size < 0L) {
            throw IOException("the host returned an invalid file handle")
        }
        return MacFilesOpenFile(opened.handle, opened.size)
    }

    override fun readRange(handle: Long, offset: Long, length: Int): ByteArray {
        requireRange(handle, offset, length)
        val response =
            call(Response.ResultCase.HOST_READ_RANGE) {
                setHostReadRange(
                    HostReadRange.newBuilder().setHandle(handle).setOffset(offset).setLength(length)
                )
            }
        val bytes = response.hostReadRange.data.toByteArray()
        if (bytes.size > length) throw IOException("the host returned an oversized file range")
        return bytes
    }

    override fun readRanges(handle: Long, firstOffset: Long, rangeCount: Int): List<ByteArray> {
        require(firstOffset >= 0L && rangeCount in 1..MAXIMUM_READ_AHEAD_RANGES)
        if (firstOffset > Long.MAX_VALUE - (rangeCount - 1L) * MAXIMUM_HOST_FILE_RANGE_BYTES) {
            throw IOException("the requested shared-folder range overflows")
        }

        val requests =
            (0 until rangeCount).map { index ->
                val offset = firstOffset + index * MAXIMUM_HOST_FILE_RANGE_BYTES
                CompletableFuture.supplyAsync(
                    {
                        readRange(handle, offset, MAXIMUM_HOST_FILE_RANGE_BYTES)
                    },
                    READ_EXECUTOR,
                )
            }

        val ranges =
            try {
                requests.map { it.get(HOST_REQUEST_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS) }
            } catch (interrupted: InterruptedException) {
                requests.forEach { it.cancel(true) }
                Thread.currentThread().interrupt()
                throw IOException("the shared-folder read was interrupted", interrupted)
            } catch (failure: Exception) {
                requests.forEach { it.cancel(true) }
                val cause =
                    when (failure) {
                        is ExecutionException -> failure.cause
                        is CompletionException -> failure.cause
                        else -> failure
                    }
                throw (cause as? IOException) ?: IOException("the shared-folder read failed", cause)
            }

        val bounded = ArrayList<ByteArray>(ranges.size)
        for (bytes in ranges) {
            bounded += bytes
            if (bytes.size < MAXIMUM_HOST_FILE_RANGE_BYTES) break
        }
        return bounded
    }

    override fun writeRange(handle: Long, offset: Long, data: ByteArray) {
        requireRange(handle, offset, data.size)
        call(Response.ResultCase.HOST_WRITE_RANGE) {
            setHostWriteRange(
                HostWriteRange.newBuilder()
                    .setHandle(handle)
                    .setOffset(offset)
                    .setData(com.google.protobuf.ByteString.copyFrom(data))
            )
        }
    }

    override fun closeFile(handle: Long, fsync: Boolean) {
        if (handle == 0L) throw IOException("the shared-folder handle is invalid")
        call(Response.ResultCase.HOST_CLOSE_FILE) {
            setHostCloseFile(HostCloseFile.newBuilder().setHandle(handle).setFsync(fsync))
        }
    }

    override fun createDocument(
        packageName: String,
        rootId: String,
        parentPath: String,
        name: String,
        isDirectory: Boolean,
    ): MacFilesDocument {
        val response =
            call(Response.ResultCase.HOST_CREATE_DOCUMENT) {
                setHostCreateDocument(
                    HostCreateDocument.newBuilder()
                        .setPackage(packageName)
                        .setRootId(rootId)
                        .setParentPath(parentPath)
                        .setName(name)
                        .setIsDir(isDirectory)
                )
            }
        return document(response.hostCreateDocument)
    }

    override fun deleteDocument(packageName: String, rootId: String, path: String) {
        call(Response.ResultCase.HOST_DELETE_DOCUMENT) {
            setHostDeleteDocument(
                HostDeleteDocument.newBuilder()
                    .setPackage(packageName)
                    .setRootId(rootId)
                    .setPath(path)
            )
        }
    }

    override fun renameDocument(
        packageName: String,
        rootId: String,
        path: String,
        newName: String,
    ): MacFilesDocument {
        val response =
            call(Response.ResultCase.HOST_RENAME_DOCUMENT) {
                setHostRenameDocument(
                    HostRenameDocument.newBuilder()
                        .setPackage(packageName)
                        .setRootId(rootId)
                        .setPath(path)
                        .setNewName(newName)
                )
            }
        return document(response.hostRenameDocument)
    }

    private fun call(
        expected: Response.ResultCase,
        operation: Request.Builder.() -> Unit,
    ): Response {
        val request =
            Request.newBuilder()
                .setTimeoutMs(HOST_REQUEST_TIMEOUT_MILLIS.toInt())
                .apply(operation)
                .build()
        val response = connection.requestHost(request)
        if (response.resultCase == Response.ResultCase.ERROR) throw hostFailure(response.error)
        if (response.resultCase != expected) {
            throw IOException("the host returned a mismatched shared-folder response")
        }
        return response
    }

    private fun hostFailure(error: GuestError): Exception =
        when (error.code) {
            GuestErrorCode.GUEST_ERROR_CODE_PERMISSION_DENIED ->
                SecurityException("Blocked by APKRun settings")
            GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND ->
                FileNotFoundException("the shared-folder item was not found")
            GuestErrorCode.GUEST_ERROR_CODE_RESOURCE_EXHAUSTED ->
                IOException("the shared-folder service is at capacity")
            GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE ->
                IOException("the shared folder is unavailable")
            else -> IOException("the shared-folder operation failed: ${error.code.name}")
        }

    private fun document(info: io.apkrun.guest.protocol.v1.DocInfo): MacFilesDocument {
        if (info.size < 0L || info.mtimeMs < 0L) {
            throw IOException("the host returned invalid shared-folder metadata")
        }
        return MacFilesDocument(
            path = info.path,
            name = info.name,
            isDirectory = info.isDir,
            size = info.size,
            modifiedAtMillis = info.mtimeMs,
            mimeType = info.mimeType,
        )
    }

    private fun requireRange(handle: Long, offset: Long, length: Int) {
        if (
            handle == 0L ||
                offset < 0L ||
                length !in 1..MAXIMUM_HOST_FILE_RANGE_BYTES ||
                offset > Long.MAX_VALUE - length
        ) {
            throw IOException("the shared-folder range is invalid")
        }
    }

    private companion object {
        const val MAXIMUM_PAGE_ENTRIES = 4096
        const val MAXIMUM_HOST_FILE_RANGE_BYTES = 1024 * 1024
        const val MAXIMUM_READ_AHEAD_RANGES = 4
        const val HOST_REQUEST_TIMEOUT_MILLIS = 30_000L

        val READ_EXECUTOR =
            Executors.newFixedThreadPool(16) { task ->
                Thread(task, "apkrun-files-rpc").apply { isDaemon = true }
            }
    }
}
