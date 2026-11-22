package io.apkrun.guest.files

import android.content.ActivityNotFoundException
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.widget.Toast
import io.apkrun.guest.daemon.BulkTransfers
import io.apkrun.guest.daemon.EventBus
import io.apkrun.guest.daemon.InboundTransfers
import io.apkrun.guest.protocol.v1.AccessLevel
import io.apkrun.guest.protocol.v1.BulkKind
import io.apkrun.guest.protocol.v1.ExportDecision
import io.apkrun.guest.protocol.v1.ExportFileOffered
import io.apkrun.guest.protocol.v1.ExportStart
import io.apkrun.guest.protocol.v1.FileRef
import io.apkrun.guest.protocol.v1.ImportDisposition
import io.apkrun.guest.protocol.v1.ImportFiles
import io.apkrun.guest.protocol.v1.ImportResult
import io.apkrun.guest.protocol.v1.ImportTarget
import io.apkrun.guest.protocol.v1.ResolveExport
import io.apkrun.guest.protocol.v1.SetSharedFolderAccess
import io.apkrun.guest.protocol.v1.SharedRoot
import io.apkrun.guest.runtime.AgentLog
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/**
 * The files integration of the guest agent (desktop-integration.md §6, guest-protocol.md §7.4–7.5,
 * §12): host drops become Android shares, app shares become Mac saves, and the shared-folder access
 * map drives the [MacFilesProvider].
 *
 * Import (op 45): the host pushed every file as a `.file` bulk transfer first; [import] takes the
 * assembled files from [InboundTransfers], publishes them through the `io.apkrun.guest.files`
 * provider, and fires `ACTION_SEND`/`ACTION_SEND_MULTIPLE` at the target package. When nothing
 * resolves the intent, the files go to MediaStore.Downloads and a toast says so; the result's
 * disposition tells the host which path ran.
 *
 * Export (op 51): [SaveToMacActivity] and any ACTION_SEND to "Save to Mac" register a pending offer
 * and publish `export_file_offered` (event 44). The host's `ResolveExport` accepts — the file
 * leaves as a `.file` transfer and the response carries `export_start` — or declines.
 *
 * [applySharedAccess] keeps the latest `SetSharedFolderAccess` (op 52) so the DocumentsProvider and
 * per-package checks do not need the host to re-send on every query.
 */
internal class FilesBridge(
    private val context: Context,
    private val events: EventBus,
    private val inboundTransfers: InboundTransfers,
    private val bulkTransfers: BulkTransfers,
) {

    /** One registered export offer, waiting for the host's ResolveExport. */
    class PendingExport(
        val offerId: Long,
        val uri: Uri,
        val name: String,
        val mimeType: String,
        val size: Long,
        val sourcePackage: String,
        val displayId: Int,
        /** Opened eagerly while the share grant lives, when no persistable grant exists. */
        val stream: java.io.InputStream?,
    )

    private val offerIds = AtomicLong(System.currentTimeMillis() and 0x3FFFFFFF)
    private val pendingExports = HashMap<Long, PendingExport>()

    @Volatile
    var sharedAccess: SetSharedFolderAccess? = null
        private set

    /**
     * Answers an ImportFiles request (op 45). `shareToPackage` is the only v1 target; anything else
     * fails fast on the host already, but the daemon keeps its own check.
     */
    fun import(request: ImportFiles): ImportResult {
        val files = ArrayList<File>()
        val uris = ArrayList<Uri>()
        val names = ArrayList<String>()
        for (ref: FileRef in request.filesList) {
            val file =
                inboundTransfers.take(ref.transferId)
                    ?: return result(ImportDisposition.IMPORT_DISPOSITION_UNSPECIFIED)
            files.add(file)
            uris.add(contentUri(file))
            names.add(ref.name.ifEmpty { file.name })
        }
        if (files.isEmpty()) {
            return result(ImportDisposition.IMPORT_DISPOSITION_UNSPECIFIED)
        }
        val targetPackage = request.`package`
        if (
            request.target == ImportTarget.IMPORT_TARGET_SHARE_TO_PACKAGE &&
                targetPackage.isNotEmpty()
        ) {
            val intent =
                if (uris.size == 1) {
                    Intent(Intent.ACTION_SEND)
                        .putExtra(Intent.EXTRA_STREAM, uris[0])
                        .setType(mimeOf(request.filesList[0].mimeType))
                } else {
                    Intent(Intent.ACTION_SEND_MULTIPLE)
                        .putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                        .setType(commonMime(request.filesList.map { it.mimeType }))
                }
            intent
                .setPackage(targetPackage)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                context.startActivity(intent)
                return ImportResult.newBuilder()
                    .setDisposition(ImportDisposition.IMPORT_DISPOSITION_SHARED)
                    .addContentUri("package:$targetPackage")
                    .build()
            } catch (error: ActivityNotFoundException) {
                AgentLog.info("$targetPackage does not accept the share; falling back to Downloads")
            } catch (error: SecurityException) {
                AgentLog.info("$targetPackage rejected the share; falling back to Downloads")
            }
        }
        if (saveToDownloads(files, names, request.filesList.map { it.mimeType })) {
            Handler(context.mainLooper).post {
                Toast.makeText(context, "Saved to Downloads", Toast.LENGTH_SHORT).show()
            }
            return ImportResult.newBuilder()
                .setDisposition(ImportDisposition.IMPORT_DISPOSITION_SAVED_TO_DOWNLOADS)
                .addContentUri(MediaStore.Downloads.EXTERNAL_CONTENT_URI.toString())
                .build()
        }
        return result(ImportDisposition.IMPORT_DISPOSITION_UNSPECIFIED)
    }

    /**
     * Registers an export offer and publishes `export_file_offered` (event 44). Returns the offer
     * id, or `null` when the file metadata could not be read.
     */
    fun offerExport(
        uri: Uri,
        sourcePackage: String,
        displayId: Int,
    ): Long? {
        val meta = describe(uri) ?: return null
        // A transient share grant dies with the calling activity, so without a
        // persistable grant the stream is opened now and kept for the resolve.
        val persisted =
            try {
                context.contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
                true
            } catch (error: SecurityException) {
                false
            } catch (error: Exception) {
                false
            }
        val stream =
            if (persisted) {
                null
            } else {
                try {
                    context.contentResolver.openInputStream(uri)
                } catch (error: Exception) {
                    AgentLog.warning(
                        "the offered file could not be opened: ${error.javaClass.simpleName}"
                    )
                    return null
                }
            }
        val offerId = offerIds.incrementAndGet()
        synchronized(pendingExports) {
            pendingExports[offerId] =
                PendingExport(
                    offerId = offerId,
                    uri = uri,
                    name = meta.name,
                    mimeType = meta.mimeType,
                    size = meta.size,
                    sourcePackage = sourcePackage,
                    displayId = displayId,
                    stream = stream,
                )
        }
        events.publish { event ->
            event.exportFileOffered =
                ExportFileOffered.newBuilder()
                    .setOfferId(offerId)
                    .setName(meta.name)
                    .setMimeType(meta.mimeType)
                    .setSize(meta.size)
                    .setSourcePackage(sourcePackage)
                    .setDisplayId(displayId)
                    .build()
        }
        return offerId
    }

    /** Every pending offer of a package is dropped when its app session ends. */
    fun discardOffersOf(sourcePackage: String) {
        val doomed =
            synchronized(pendingExports) {
                val keys =
                    pendingExports.filterValues { it.sourcePackage == sourcePackage }.keys
                keys.mapNotNull { pendingExports.remove(it) }
            }
        doomed.forEach { it.stream?.close() }
    }

    /**
     * Answers a ResolveExport request (op 51). An accepted offer reads the file and sends it as a
     * `.file` transfer; the response carries `export_start` with the transfer id. A declined or
     * unknown offer answers with the empty message.
     */
    fun resolveExport(request: ResolveExport): ExportStart {
        val offer =
            synchronized(pendingExports) { pendingExports.remove(request.offerId) }
                ?: return ExportStart.getDefaultInstance()
        if (request.decision != ExportDecision.EXPORT_DECISION_ACCEPT) {
            offer.stream?.close()
            return ExportStart.getDefaultInstance()
        }
        // The file is framed as it is read; it never lands in memory whole
        // (desktop-integration.md §6.3). An eagerly opened stream survives the
        // share activity's transient grant; a persistable grant is reopened.
        val stream =
            offer.stream
                ?: try {
                    context.contentResolver.openInputStream(offer.uri)
                } catch (error: Exception) {
                    AgentLog.warning(
                        "the offered file could not be read: ${error.javaClass.simpleName}"
                    )
                    null
                } ?: return ExportStart.getDefaultInstance()
        val transferId =
            bulkTransfers.sendStream(
                BulkKind.BULK_KIND_FILE,
                offer.name,
                offer.mimeType,
                offer.size,
                stream,
            ) ?: return ExportStart.getDefaultInstance()
        return ExportStart.newBuilder().setTransferId(transferId).build()
    }

    /** Applies a SetSharedFolderAccess (op 52); the providers read [sharedAccess]. */
    fun applySharedAccess(request: SetSharedFolderAccess) {
        sharedAccess = request
    }

    /** The effective access of [packageName] on [root]: min(root cap, package setting). */
    fun accessFor(root: SharedRoot, packageName: String): AccessLevel {
        val granted =
            sharedAccess?.accessList?.firstOrNull { it.`package` == packageName }?.access
                ?: AccessLevel.ACCESS_LEVEL_UNSPECIFIED
        if (granted == AccessLevel.ACCESS_LEVEL_UNSPECIFIED) {
            return AccessLevel.ACCESS_LEVEL_UNSPECIFIED
        }
        return if (
            granted == AccessLevel.ACCESS_LEVEL_READ_WRITE &&
                root.maxAccess == AccessLevel.ACCESS_LEVEL_READ_WRITE
        ) {
            AccessLevel.ACCESS_LEVEL_READ_WRITE
        } else {
            AccessLevel.ACCESS_LEVEL_READ_ONLY
        }
    }

    /** The shared roots the host last pushed, or an empty list before the first push. */
    fun roots(): List<SharedRoot> = sharedAccess?.rootsList ?: emptyList()

    private fun result(disposition: ImportDisposition): ImportResult =
        ImportResult.newBuilder().setDisposition(disposition).build()

    private fun contentUri(file: File): Uri =
        Uri.parse(
            "content://${io.apkrun.guest.daemon.TransferFileProvider.AUTHORITY}/transfers/${file.name}"
        )

    private class ExportMeta(val name: String, val mimeType: String, val size: Long)

    private fun describe(uri: Uri): ExportMeta? {
        val resolver: ContentResolver = context.contentResolver
        var name = uri.lastPathSegment ?: "file"
        var size = -1L
        try {
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (cursor.moveToFirst()) {
                    if (nameColumn >= 0) cursor.getString(nameColumn)?.let { name = it }
                    if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) {
                        size = cursor.getLong(sizeColumn)
                    }
                }
            }
        } catch (error: Exception) {
            return null
        }
        return ExportMeta(name, resolver.getType(uri) ?: "application/octet-stream", size)
    }

    private fun saveToDownloads(
        files: List<File>,
        names: List<String>,
        mimes: List<String>,
    ): Boolean {
        val resolver = context.contentResolver
        for (index in files.indices) {
            val values =
                ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, names[index])
                    put(MediaStore.Downloads.MIME_TYPE, mimeOf(mimes[index]))
                }
            val uri =
                resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return false
            try {
                resolver.openOutputStream(uri)?.use { output ->
                    files[index].inputStream().use { it.copyTo(output) }
                } ?: return false
            } catch (error: Exception) {
                AgentLog.warning("a download could not be written: ${error.javaClass.simpleName}")
                return false
            }
        }
        return true
    }

    private fun mimeOf(mime: String): String = mime.ifEmpty { "application/octet-stream" }

    private fun commonMime(mimes: List<String>): String {
        val types = mimes.map { it.substringBefore('/') }.distinct()
        return if (types.size == 1) "${types[0]}/*" else "*/*"
    }
}
