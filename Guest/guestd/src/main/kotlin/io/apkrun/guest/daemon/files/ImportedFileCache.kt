package io.apkrun.guest.daemon.files

import io.apkrun.guest.daemon.PackageName
import io.apkrun.guest.protocol.v1.BulkAckStatus
import io.apkrun.guest.protocol.v1.BulkBegin
import io.apkrun.guest.protocol.v1.FileRef
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest
import java.util.Properties
import java.util.UUID

/**
 * Bounded, app-private storage for files received on the bulk stream.
 *
 * Transfer IDs identify an in-flight protocol transfer only. Files on disk use random names so host
 * supplied names can never select a path. Metadata is kept private beside each file and is never
 * included in logs.
 */
internal class ImportedFileCache(
    private val root: File,
    private val nowMillis: () -> Long = System::currentTimeMillis,
) {
    private val active = LinkedHashMap<Long, Incoming>()
    private val records = LinkedHashMap<Long, Record>()

    init {
        root.mkdirs()
        loadRecords()
        cleanupExpired()
    }

    /** Starts an incoming transfer, returning an immediate rejection when it cannot be accepted. */
    @Synchronized
    fun begin(
        transferId: Long,
        begin: BulkBegin,
        transferOwner: Any = DEFAULT_TRANSFER_OWNER,
    ): BulkAckStatus? {
        cleanupExpiredLocked()
        val size = begin.size
        if (
            transferId <= 0L ||
                transferId % 2L != 0L ||
                begin.kind != io.apkrun.guest.protocol.v1.BulkKind.BULK_KIND_FILE ||
                size < 0L ||
                size > MAXIMUM_FILE_BYTES ||
                !validName(begin.name) ||
                !validMimeType(begin.mimeType) ||
                (begin.hasSha256() && begin.sha256.size() != SHA256_BYTES) ||
                active.containsKey(transferId) ||
                records.containsKey(transferId)
        ) {
            return if (size > MAXIMUM_FILE_BYTES || size < 0L) {
                BulkAckStatus.BULK_ACK_STATUS_TOO_LARGE
            } else {
                BulkAckStatus.BULK_ACK_STATUS_REJECTED
            }
        }
        if (
            active.size >= MAXIMUM_ACTIVE_TRANSFERS ||
                records.size + active.size >= MAXIMUM_CACHE_ITEMS ||
                records.values.count { it.packageOwner == null } + active.size >=
                    MAXIMUM_PENDING_ITEMS
        ) {
            return BulkAckStatus.BULK_ACK_STATUS_REJECTED
        }
        val reservedBytes =
            records.values.sumOf { it.size } + active.values.sumOf { it.expectedSize }
        if (size > MAXIMUM_CACHE_BYTES - reservedBytes) {
            return BulkAckStatus.BULK_ACK_STATUS_TOO_LARGE
        }

        val storageId = UUID.randomUUID().toString()
        val part = File(root, "$storageId.part")
        try {
            active[transferId] =
                Incoming(
                    transferId = transferId,
                    storageId = storageId,
                    name = begin.name,
                    mimeType = begin.mimeType,
                    expectedSize = size,
                    expectedDigest = if (begin.hasSha256()) begin.sha256.toByteArray() else null,
                    transferOwner = transferOwner,
                    partFile = part,
                    output = FileOutputStream(part),
                    digest = MessageDigest.getInstance("SHA-256"),
                )
        } catch (_: IOException) {
            part.delete()
            return BulkAckStatus.BULK_ACK_STATUS_REJECTED
        }
        return null
    }

    /** Writes one bounded chunk, returning an acknowledgement status only when it rejects. */
    @Synchronized
    fun append(
        transferId: Long,
        bytes: ByteArray,
        transferOwner: Any = DEFAULT_TRANSFER_OWNER,
    ): BulkAckStatus? {
        val incoming = active[transferId] ?: return BulkAckStatus.BULK_ACK_STATUS_REJECTED
        if (incoming.transferOwner !== transferOwner) {
            return BulkAckStatus.BULK_ACK_STATUS_REJECTED
        }
        if (bytes.isEmpty() || bytes.size > MAXIMUM_CHUNK_BYTES) {
            discard(incoming)
            return if (bytes.size > MAXIMUM_CHUNK_BYTES) {
                BulkAckStatus.BULK_ACK_STATUS_TOO_LARGE
            } else {
                BulkAckStatus.BULK_ACK_STATUS_REJECTED
            }
        }
        if (incoming.receivedBytes > incoming.expectedSize - bytes.size) {
            discard(incoming)
            return BulkAckStatus.BULK_ACK_STATUS_TOO_LARGE
        }
        return try {
            incoming.output.write(bytes)
            incoming.digest.update(bytes)
            incoming.receivedBytes += bytes.size
            null
        } catch (_: IOException) {
            discard(incoming)
            BulkAckStatus.BULK_ACK_STATUS_REJECTED
        }
    }

    /** Completes and atomically publishes a file after exact size and SHA-256 checks. */
    @Synchronized
    fun end(
        transferId: Long,
        endDigest: ByteArray,
        transferOwner: Any = DEFAULT_TRANSFER_OWNER,
    ): BulkAckStatus {
        val incoming = active[transferId] ?: return BulkAckStatus.BULK_ACK_STATUS_REJECTED
        if (incoming.transferOwner !== transferOwner) {
            return BulkAckStatus.BULK_ACK_STATUS_REJECTED
        }
        if (incoming.receivedBytes != incoming.expectedSize) {
            discard(incoming)
            return BulkAckStatus.BULK_ACK_STATUS_REJECTED
        }
        val expectedDigest = incoming.expectedDigest ?: endDigest
        if (
            expectedDigest.size != SHA256_BYTES ||
                (incoming.expectedDigest != null && endDigest.isNotEmpty()) ||
                !MessageDigest.isEqual(incoming.digest.digest(), expectedDigest)
        ) {
            discard(incoming)
            return BulkAckStatus.BULK_ACK_STATUS_HASH_MISMATCH
        }

        return try {
            incoming.output.fd.sync()
            incoming.output.close()
            val file = File(root, "${incoming.storageId}.bin")
            if (!incoming.partFile.renameTo(file)) {
                discard(incoming, closeOutput = false)
                return BulkAckStatus.BULK_ACK_STATUS_REJECTED
            }
            val record =
                Record(
                    transferId = transferId,
                    storageId = incoming.storageId,
                    name = incoming.name,
                    mimeType = incoming.mimeType,
                    size = incoming.expectedSize,
                    createdAtMillis = nowMillis(),
                    packageOwner = null,
                )
            try {
                writeRecord(record)
            } catch (_: IOException) {
                file.delete()
                incoming.partFile.delete()
                active.remove(transferId)
                return BulkAckStatus.BULK_ACK_STATUS_REJECTED
            }
            records[transferId] = record
            active.remove(transferId)
            BulkAckStatus.BULK_ACK_STATUS_OK
        } catch (_: IOException) {
            discard(incoming, closeOutput = false)
            BulkAckStatus.BULK_ACK_STATUS_REJECTED
        }
    }

    /** Aborts an in-flight transfer, if any. */
    @Synchronized
    fun abort(transferId: Long, transferOwner: Any = DEFAULT_TRANSFER_OWNER) {
        active[transferId]?.takeIf { it.transferOwner === transferOwner }?.let(::discard)
    }

    /** Removes only this bulk connection's incomplete files when its stream closes. */
    @Synchronized
    fun abortIncomplete(transferOwner: Any = DEFAULT_TRANSFER_OWNER) {
        active.values.filter { it.transferOwner === transferOwner }.toList().forEach(::discard)
    }

    /**
     * Validates every protocol reference before assigning it to [packageName].
     *
     * The update is all-or-nothing. Repeated imports by the same package are allowed while cached;
     * a different package cannot claim an already-owned transfer.
     */
    @Synchronized
    fun claim(
        refs: List<FileRef>,
        packageName: String,
    ): List<CachedFile> {
        cleanupExpiredLocked()
        if (refs.map { it.transferId }.toSet().size != refs.size) {
            throw CacheFailure.NotAvailable
        }
        val selected = refs.map { ref -> find(ref, packageName) }
        selected.forEach { record ->
            if (record.packageOwner != null && record.packageOwner != packageName) {
                throw CacheFailure.NotAvailable
            }
        }
        val newlyClaimed =
            selected.filter { it.packageOwner == null }.map { it.copy(packageOwner = packageName) }
        val stagedMetadata = mutableListOf<Pair<File, File>>()
        try {
            newlyClaimed.forEach { record ->
                val temporary = writeRecordTemporary(record)
                stagedMetadata += temporary to metadataFile(record.storageId)
            }
            stagedMetadata.forEach { (temporary, destination) ->
                if (!temporary.renameTo(destination)) {
                    throw IOException("metadata could not be committed")
                }
            }
            newlyClaimed.forEach { record -> records[record.transferId] = record }
        } catch (error: IOException) {
            stagedMetadata.forEach { (temporary, _) -> temporary.delete() }
            selected
                .filter { it.packageOwner == null }
                .forEach { original ->
                    runCatching { writeRecord(original) }
                    records[original.transferId] = original
                }
            throw error
        }
        return selected.map { record ->
            val claimed = records.getValue(record.transferId)
            CachedFile(
                claimed.storageId,
                claimed.name,
                claimed.mimeType,
                claimed.size,
                dataFile(claimed),
            )
        }
    }

    /** Resolves pending references for a Downloads copy without assigning an app share grant. */
    @Synchronized
    fun resolve(refs: List<FileRef>): List<CachedFile> {
        cleanupExpiredLocked()
        if (refs.map { it.transferId }.toSet().size != refs.size) {
            throw CacheFailure.NotAvailable
        }
        val selected = refs.map { ref -> find(ref, packageName = "") }
        if (selected.any { it.packageOwner != null }) throw CacheFailure.NotAvailable
        return selected.map { record ->
            CachedFile(
                record.storageId,
                record.name,
                record.mimeType,
                record.size,
                dataFile(record),
            )
        }
    }

    /** Reverts ownership when Android could not launch the target application. */
    @Synchronized
    fun release(refs: List<FileRef>, packageName: String) {
        refs.forEach { ref ->
            val record = records[ref.transferId] ?: return@forEach
            if (matches(record, ref) && record.packageOwner == packageName) {
                val pending = record.copy(packageOwner = null)
                writeRecord(pending)
                records[record.transferId] = pending
            }
        }
    }

    /** Deletes cache entries after successfully copying them to Downloads. */
    @Synchronized
    fun remove(refs: List<FileRef>) {
        refs.forEach { ref ->
            val record = records[ref.transferId] ?: return@forEach
            if (matches(record, ref)) delete(record)
        }
    }

    /** Deletes all items granted to an application that Android has uninstalled. */
    @Synchronized
    fun removePackage(packageName: String) {
        records.values.filter { it.packageOwner == packageName }.toList().forEach(::delete)
    }

    /** Removes expired entries; safe to call periodically and at each cache operation. */
    @Synchronized fun cleanupExpired() = cleanupExpiredLocked()

    /** Metadata and file path used by the private ContentProvider. */
    @Synchronized
    fun forProvider(storageId: String, callingPackage: String): CachedFile? {
        records.clear()
        loadRecords()
        cleanupExpiredLocked()
        val record =
            records.values.firstOrNull {
                it.storageId == storageId && it.packageOwner == callingPackage
            } ?: return null
        val file = dataFile(record)
        if (!file.isFile || file.length() != record.size) {
            delete(record)
            return null
        }
        return CachedFile(record.storageId, record.name, record.mimeType, record.size, file)
    }

    private fun find(ref: FileRef, packageName: String): Record {
        val record =
            records[ref.transferId]?.takeIf { matches(it, ref) && dataFile(it).isFile }
                ?: throw CacheFailure.NotAvailable
        if (record.packageOwner != null && record.packageOwner != packageName) {
            throw CacheFailure.NotAvailable
        }
        return record
    }

    private fun matches(record: Record, ref: FileRef): Boolean =
        record.transferId == ref.transferId &&
            record.name == ref.name &&
            record.mimeType == ref.mimeType &&
            record.size == ref.size

    private fun cleanupExpiredLocked() {
        val cutoff = nowMillis() - MAXIMUM_AGE_MILLIS
        records.values.filter { it.createdAtMillis <= cutoff }.toList().forEach(::delete)
        root
            .listFiles()
            ?.filter { it.name.endsWith(".part") && it.lastModified() <= cutoff }
            ?.forEach(File::delete)
    }

    private fun delete(record: Record) {
        dataFile(record).delete()
        metadataFile(record.storageId).delete()
        records.remove(record.transferId)
    }

    private fun discard(incoming: Incoming, closeOutput: Boolean = true) {
        active.remove(incoming.transferId)
        if (closeOutput) runCatching { incoming.output.close() }
        incoming.partFile.delete()
    }

    private fun dataFile(record: Record) = File(root, "${record.storageId}.bin")

    private fun metadataFile(storageId: String) = File(root, "$storageId.meta")

    private fun writeRecord(record: Record) {
        val temporary = writeRecordTemporary(record)
        if (!temporary.renameTo(metadataFile(record.storageId))) {
            temporary.delete()
            throw IOException("metadata could not be committed")
        }
    }

    private fun writeRecordTemporary(record: Record): File {
        val properties =
            Properties().apply {
                setProperty("transfer_id", record.transferId.toString())
                setProperty("storage_id", record.storageId)
                setProperty("name", record.name)
                setProperty("mime_type", record.mimeType)
                setProperty("size", record.size.toString())
                setProperty("created_at", record.createdAtMillis.toString())
                setProperty("package_owner", record.packageOwner.orEmpty())
            }
        val temporary = File(root, "${record.storageId}.meta.part")
        FileOutputStream(temporary).use { stream ->
            properties.store(stream, null)
            stream.fd.sync()
        }
        return temporary
    }

    private fun loadRecords() {
        root
            .listFiles()
            ?.filter { it.name.endsWith(".meta") }
            ?.forEach { metadata ->
                try {
                    val properties = Properties().apply { metadata.inputStream().use(::load) }
                    val storageId = properties.getProperty("storage_id").orEmpty()
                    if (
                        !UUID.fromString(storageId).toString().equals(storageId, ignoreCase = true)
                    ) {
                        throw IllegalArgumentException("invalid storage identifier")
                    }
                    val transferId = properties.getProperty("transfer_id").toLong()
                    val name = properties.getProperty("name")
                    val mimeType = properties.getProperty("mime_type")
                    val size = properties.getProperty("size").toLong()
                    val createdAt = properties.getProperty("created_at").toLong()
                    val owner = properties.getProperty("package_owner").orEmpty().ifEmpty { null }
                    if (
                        transferId <= 0L ||
                            transferId % 2L != 0L ||
                            !validName(name) ||
                            !validMimeType(mimeType) ||
                            size < 0L ||
                            size > MAXIMUM_FILE_BYTES ||
                            (owner != null && !PackageName.isValid(owner)) ||
                            !File(root, "$storageId.bin").isFile ||
                            File(root, "$storageId.bin").length() != size ||
                            records.containsKey(transferId)
                    ) {
                        throw IllegalArgumentException("invalid cache metadata")
                    }
                    records[transferId] =
                        Record(transferId, storageId, name, mimeType, size, createdAt, owner)
                } catch (_: Exception) {
                    metadata.delete()
                    metadata.name.removeSuffix(".meta").let { storageId ->
                        if (storageId.matches(UUID_PATTERN)) File(root, "$storageId.bin").delete()
                    }
                }
            }
    }

    private data class Incoming(
        val transferId: Long,
        val storageId: String,
        val name: String,
        val mimeType: String,
        val expectedSize: Long,
        val expectedDigest: ByteArray?,
        val transferOwner: Any,
        val partFile: File,
        val output: FileOutputStream,
        val digest: MessageDigest,
        var receivedBytes: Long = 0L,
    )

    private data class Record(
        val transferId: Long,
        val storageId: String,
        val name: String,
        val mimeType: String,
        val size: Long,
        val createdAtMillis: Long,
        val packageOwner: String?,
    )

    internal data class CachedFile(
        val storageId: String,
        val name: String,
        val mimeType: String,
        val size: Long,
        val file: File,
    )

    internal sealed class CacheFailure : Exception() {
        data object NotAvailable : CacheFailure()
    }

    companion object {
        const val MAXIMUM_FILES_PER_IMPORT = 20
        const val MAXIMUM_FILE_BYTES = 2L * 1024L * 1024L * 1024L
        const val MAXIMUM_IMPORT_BYTES = 4L * 1024L * 1024L * 1024L
        const val MAXIMUM_CHUNK_BYTES = 1024 * 1024
        const val MAXIMUM_ACTIVE_TRANSFERS = 4
        const val MAXIMUM_PENDING_ITEMS = 20
        const val MAXIMUM_CACHE_ITEMS = 256
        const val MAXIMUM_CACHE_BYTES = MAXIMUM_IMPORT_BYTES
        const val MAXIMUM_AGE_MILLIS = 24L * 60L * 60L * 1000L

        private const val SHA256_BYTES = 32
        internal val DEFAULT_TRANSFER_OWNER = Any()
        private val UUID_PATTERN = Regex("[0-9a-fA-F-]{36}")
        private val MIME_TOKEN = Regex("[A-Za-z0-9!#$&^_.+*-]+")

        private fun validName(value: String?): Boolean =
            value != null &&
                value.isNotEmpty() &&
                value.length <= 255 &&
                value != "." &&
                value != ".." &&
                value.none { it == '/' || it == '\\' || it == '\u0000' || it.isISOControl() }

        private fun validMimeType(value: String?): Boolean {
            if (value == null || value.isEmpty()) return value != null
            if (value.length > 255) return false
            val parts = value.split('/')
            return parts.size == 2 &&
                parts.all(MIME_TOKEN::matches) &&
                !(parts[0] == "*" && parts[1] != "*")
        }
    }
}
