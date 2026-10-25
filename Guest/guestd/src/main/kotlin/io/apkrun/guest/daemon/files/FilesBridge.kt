package io.apkrun.guest.daemon.files

import android.app.ActivityOptions
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.widget.Toast
import io.apkrun.guest.daemon.GuestFailure
import io.apkrun.guest.daemon.PackageName
import io.apkrun.guest.protocol.v1.BulkAckStatus
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.FileRef
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ImportDisposition
import io.apkrun.guest.protocol.v1.ImportFiles
import io.apkrun.guest.protocol.v1.ImportResult
import io.apkrun.guest.protocol.v1.ImportTarget
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.ArrayList

private const val CACHE_DIRECTORY = "files/import"
private const val DEFAULT_MIME_TYPE = "application/octet-stream"
private const val FILES_AUTHORITY = "io.apkrun.guest.files"

/** Receives host files and delivers them through Android's ordinary share and Downloads APIs. */
internal class FilesBridge(
    private val cache: ImportedFileCache,
    private val displayExists: (Int) -> Boolean,
    private val platform: FilesBridgePlatform,
) {
    /** Processes one host-to-guest bulk frame and returns a status when an ACK should be sent. */
    fun receive(
        frame: BulkFrame,
        transferOwner: Any = ImportedFileCache.DEFAULT_TRANSFER_OWNER,
    ): BulkAckStatus? =
        when (frame.kindCase) {
            BulkFrame.KindCase.BEGIN -> cache.begin(frame.transferId, frame.begin, transferOwner)
            BulkFrame.KindCase.CHUNK ->
                cache.append(frame.transferId, frame.chunk.toByteArray(), transferOwner)
            BulkFrame.KindCase.END ->
                cache.end(frame.transferId, frame.end.sha256.toByteArray(), transferOwner)
            BulkFrame.KindCase.ABORT -> {
                cache.abort(frame.transferId, transferOwner)
                null
            }
            BulkFrame.KindCase.ACK,
            BulkFrame.KindCase.KIND_NOT_SET -> BulkAckStatus.BULK_ACK_STATUS_REJECTED
        }

    /** Validates, shares, or saves the exact files listed by an ImportFiles request. */
    fun import(request: ImportFiles): ImportResult {
        val refs = validateRequest(request)
        if (request.target == ImportTarget.IMPORT_TARGET_DOWNLOADS) {
            return saveToDownloads(refs)
        }

        val packageName = request.getPackage()
        val files =
            try {
                cache.claim(refs, packageName)
            } catch (_: ImportedFileCache.CacheFailure) {
                throw unavailableFile()
            } catch (_: IOException) {
                throw unavailableFile()
            }
        val shared =
            try {
                platform.hasShareTarget(packageName, files) &&
                    platform.share(packageName, request.displayId, files)
            } catch (_: ActivityNotFoundException) {
                false
            }
        if (shared) {
            return ImportResult.newBuilder()
                .addAllContentUri(files.map { platform.contentUri(it.storageId) })
                .setDisposition(ImportDisposition.IMPORT_DISPOSITION_SHARED)
                .build()
        }

        cache.release(refs, packageName)
        return saveToDownloads(refs)
    }

    /** Called for non-replacement package removal, so grants do not outlive their target app. */
    fun removePackage(packageName: String) = cache.removePackage(packageName)

    /** Removes expired records once an hour while the persistent custom-image agent is alive. */
    fun cleanupExpired() = cache.cleanupExpired()

    /** Incomplete transfers are scoped to their bulk connection and are deleted on disconnect. */
    fun abortIncompleteTransfers(transferOwner: Any = ImportedFileCache.DEFAULT_TRANSFER_OWNER) =
        cache.abortIncomplete(transferOwner)

    private fun saveToDownloads(refs: List<FileRef>): ImportResult {
        val files =
            try {
                cache.resolve(refs)
            } catch (_: ImportedFileCache.CacheFailure) {
                throw unavailableFile()
            }
        val uris =
            try {
                platform.saveToDownloads(files)
            } catch (_: IOException) {
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INTERNAL,
                    "the files could not be saved to Android Downloads",
                )
            }
        cache.remove(refs)
        platform.showSavedToDownloads()
        return ImportResult.newBuilder()
            .addAllContentUri(uris)
            .setDisposition(ImportDisposition.IMPORT_DISPOSITION_SAVED_TO_DOWNLOADS)
            .build()
    }

    private fun validateRequest(request: ImportFiles): List<FileRef> {
        if (request.filesCount !in 1..ImportedFileCache.MAXIMUM_FILES_PER_IMPORT) {
            throw invalidRequest("the number of files is outside the supported range")
        }
        if (request.displayId < 0) {
            throw invalidRequest("the display ID is not valid")
        }
        if (
            request.target == ImportTarget.UNRECOGNIZED ||
                request.target == ImportTarget.IMPORT_TARGET_UNSPECIFIED
        ) {
            throw invalidRequest("the import target is not supported")
        }
        if (
            request.target == ImportTarget.IMPORT_TARGET_SHARE_TO_PACKAGE &&
                (!request.hasPackage() || !PackageName.isValid(request.getPackage()))
        ) {
            throw invalidRequest("the package name is not valid")
        }
        if (
            request.target == ImportTarget.IMPORT_TARGET_SHARE_TO_PACKAGE &&
                !displayExists(request.displayId)
        ) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the display is not known",
                mapOf("display_id" to request.displayId.toString()),
            )
        }

        var total = 0L
        val transferIds = HashSet<Long>()
        for (ref in request.filesList) {
            if (
                ref.transferId <= 0L ||
                    ref.transferId % 2L != 0L ||
                    !transferIds.add(ref.transferId) ||
                    ref.size < 0L ||
                    ref.size > ImportedFileCache.MAXIMUM_FILE_BYTES ||
                    ref.name.isEmpty() ||
                    ref.name.length > 255 ||
                    ref.mimeType.length > 255
            ) {
                throw invalidRequest("a file reference is not valid")
            }
            if (ref.size > ImportedFileCache.MAXIMUM_IMPORT_BYTES - total) {
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_RESOURCE_EXHAUSTED,
                    "the imported files exceed the supported size limit",
                )
            }
            total += ref.size
        }
        return request.filesList
    }

    private fun unavailableFile() =
        GuestFailure(
            GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
            "a transferred file is missing or no longer available",
        )

    private fun invalidRequest(message: String) =
        GuestFailure(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, message)

    internal interface FilesBridgePlatform {
        fun contentUri(storageId: String): String

        fun hasShareTarget(packageName: String, files: List<ImportedFileCache.CachedFile>): Boolean

        fun share(
            packageName: String,
            displayId: Int,
            files: List<ImportedFileCache.CachedFile>,
        ): Boolean

        @Throws(IOException::class)
        fun saveToDownloads(files: List<ImportedFileCache.CachedFile>): List<String>

        fun showSavedToDownloads()
    }

    companion object {
        fun create(context: Context, displayExists: (Int) -> Boolean): FilesBridge {
            val appContext = context.applicationContext
            return FilesBridge(
                cache = ImportedFileCache(File(appContext.cacheDir, CACHE_DIRECTORY)),
                displayExists = displayExists,
                platform = AndroidFilesBridgePlatform(appContext),
            )
        }
    }

    private class AndroidFilesBridgePlatform(private val context: Context) : FilesBridgePlatform {
        private val resolver = context.contentResolver

        override fun contentUri(storageId: String): String = fileUri(storageId).toString()

        override fun hasShareTarget(
            packageName: String,
            files: List<ImportedFileCache.CachedFile>,
        ): Boolean {
            val intent = shareIntent(packageName, files)
            return context.packageManager
                .queryIntentActivities(intent, android.content.pm.PackageManager.MATCH_DEFAULT_ONLY)
                .any { it.activityInfo?.packageName == packageName }
        }

        override fun share(
            packageName: String,
            displayId: Int,
            files: List<ImportedFileCache.CachedFile>,
        ): Boolean {
            val intent = shareIntent(packageName, files)
            val options = ActivityOptions.makeBasic().setLaunchDisplayId(displayId)
            return try {
                context.startActivity(intent, options.toBundle())
                true
            } catch (_: ActivityNotFoundException) {
                false
            }
        }

        override fun saveToDownloads(files: List<ImportedFileCache.CachedFile>): List<String> {
            val created = ArrayList<Uri>(files.size)
            try {
                files.forEach { file ->
                    val values =
                        ContentValues().apply {
                            put(MediaStore.Downloads.DISPLAY_NAME, file.name)
                            put(
                                MediaStore.Downloads.MIME_TYPE,
                                file.mimeType.ifEmpty { DEFAULT_MIME_TYPE },
                            )
                            put(
                                MediaStore.Downloads.RELATIVE_PATH,
                                Environment.DIRECTORY_DOWNLOADS,
                            )
                        }
                    val uri =
                        resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                            ?: throw IOException("Downloads rejected the file")
                    created += uri
                    val output =
                        resolver.openOutputStream(uri, "w")
                            ?: throw IOException("Downloads did not open the file")
                    output.use { destination ->
                        FileInputStream(file.file).use { source -> source.copyTo(destination) }
                    }
                }
                return created.map(Uri::toString)
            } catch (error: Exception) {
                created.forEach { uri -> runCatching { resolver.delete(uri, null, null) } }
                if (error is IOException) throw error
                throw IOException("Downloads could not save the files", error)
            }
        }

        override fun showSavedToDownloads() {
            Handler(Looper.getMainLooper()).post {
                Toast.makeText(context, "Saved to Downloads", Toast.LENGTH_SHORT).show()
            }
        }

        private fun shareIntent(
            packageName: String,
            files: List<ImportedFileCache.CachedFile>,
        ): Intent {
            val uris = files.map { fileUri(it.storageId) }
            val mimeTypes = files.map { it.mimeType.ifEmpty { DEFAULT_MIME_TYPE } }.distinct()
            val mimeType = if (mimeTypes.size == 1) mimeTypes.single() else "*/*"
            val action = if (uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE
            val intent =
                Intent(action)
                    .setPackage(packageName)
                    .setType(mimeType)
                    .addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK
                    )
            val clipData = ClipData.newUri(resolver, files.first().name, uris.first())
            uris.drop(1).forEach { clipData.addItem(ClipData.Item(it)) }
            intent.clipData = clipData
            if (uris.size == 1) {
                intent.putExtra(Intent.EXTRA_STREAM, uris.single())
            } else {
                intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            }
            if (mimeTypes.size > 1)
                intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toTypedArray())
            return intent
        }

        private fun fileUri(storageId: String): Uri =
            Uri.parse("content://$FILES_AUTHORITY/shared/$storageId")
    }
}
