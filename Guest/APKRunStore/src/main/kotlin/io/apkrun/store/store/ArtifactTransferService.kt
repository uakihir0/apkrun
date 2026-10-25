package io.apkrun.store.store

import android.content.Context
import android.os.SystemClock
import io.apkrun.guest.protocol.v1.ArchiveInfo
import io.apkrun.guest.protocol.v1.BulkAck
import io.apkrun.guest.protocol.v1.BulkAckStatus
import io.apkrun.guest.protocol.v1.BulkBegin
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InspectArchive
import io.apkrun.guest.runtime.AgentLog
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicLong

/** Writes host-to-guest APK transfers without buffering their contents in memory. */
class ArtifactTransferService private constructor(configuration: Configuration) {
    constructor(
        context: Context,
        installService: InstallService,
        maxConcurrentTransfers: Int = MAXIMUM_ACTIVE_TRANSFERS,
    ) : this(
        Configuration(
            inspectionDirectory = File(context.cacheDir, "apkrun-store/inspect"),
            inspectArchives = { files ->
                ArchiveInspector(AndroidArchiveReader(context.packageManager)).inspect(files)
            },
            openInstallArtifact = { controlSessionId, installId, name, size, digest ->
                installService.openArtifact(controlSessionId, installId, name, size, digest)
            },
            maxConcurrentTransfers = maxConcurrentTransfers,
            maxInspectionArtifacts = MAXIMUM_INSPECTION_ARTIFACTS,
            maxInspectionBytes = MAXIMUM_INSPECTION_BYTES,
            inspectionMaxAgeMillis = INSPECTION_MAX_AGE_MILLIS,
            clockMillis = SystemClock::elapsedRealtime,
        )
    )

    internal constructor(
        inspectionDirectory: File,
        inspectArchives: (List<File>) -> ArchiveInfo,
        openInstallArtifact: InstallArtifactOpener,
        maxConcurrentTransfers: Int = MAXIMUM_ACTIVE_TRANSFERS,
        maxInspectionArtifacts: Int = MAXIMUM_INSPECTION_ARTIFACTS,
        maxInspectionBytes: Long = MAXIMUM_INSPECTION_BYTES,
        inspectionMaxAgeMillis: Long = INSPECTION_MAX_AGE_MILLIS,
        clockMillis: () -> Long = SystemClock::elapsedRealtime,
    ) : this(
        Configuration(
            inspectionDirectory = inspectionDirectory,
            inspectArchives = inspectArchives,
            openInstallArtifact = openInstallArtifact,
            maxConcurrentTransfers = maxConcurrentTransfers,
            maxInspectionArtifacts = maxInspectionArtifacts,
            maxInspectionBytes = maxInspectionBytes,
            inspectionMaxAgeMillis = inspectionMaxAgeMillis,
            clockMillis = clockMillis,
        )
    )

    private val inspectionDirectory = configuration.inspectionDirectory
    private val inspectArchives = configuration.inspectArchives
    private val openInstallArtifact = configuration.openInstallArtifact
    private val maxConcurrentTransfers = configuration.maxConcurrentTransfers
    private val maxInspectionArtifacts = configuration.maxInspectionArtifacts
    private val maxInspectionBytes = configuration.maxInspectionBytes
    private val inspectionMaxAgeMillis = configuration.inspectionMaxAgeMillis
    private val clockMillis = configuration.clockMillis
    private val active = ConcurrentHashMap<Long, Transfer>()
    private val activeTransferSlots = Semaphore(maxConcurrentTransfers)
    private val completedForInspection = ConcurrentHashMap<Long, CompletedArtifact>()
    private val temporarySequence = AtomicLong()
    private val inspectionCapacityLock = Any()
    private var reservedInspectionArtifacts = 0
    private var reservedInspectionBytes = 0L

    init {
        require(maxConcurrentTransfers > 0)
        require(maxInspectionArtifacts > 0)
        require(maxInspectionBytes > 0L)
        require(inspectionMaxAgeMillis > 0L)
    }

    /** Handles a BulkFrame from the artifact socket. A non-null ack is sent after BulkEnd. */
    fun accept(
        frame: BulkFrame,
        controlSessionId: String,
    ): BulkAck? =
        when (frame.kindCase) {
            BulkFrame.KindCase.BEGIN -> begin(frame.transferId, frame.begin, controlSessionId)
            BulkFrame.KindCase.CHUNK -> writeChunk(frame.transferId, frame.chunk.toByteArray())
            BulkFrame.KindCase.END -> end(frame.transferId, frame.end.sha256.toByteArray())
            BulkFrame.KindCase.ABORT -> {
                abort(frame.transferId)
                null
            }
            else -> rejected()
        }

    fun inspect(request: InspectArchive): ArchiveInfo {
        expireInspectionArtifacts()
        val claimed = mutableListOf<Pair<Long, CompletedArtifact>>()
        try {
            val files =
                request.artifactsList.map { reference ->
                    val artifact =
                        completedForInspection.remove(reference.transferId)
                            ?: throw StoreFailure(
                                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                                "the inspection artifact has not been received",
                            )
                    claimed += reference.transferId to artifact
                    if (artifact.context != INSPECT_CONTEXT || artifact.name != reference.name) {
                        throw StoreFailure(
                            GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                            "the inspection artifact reference does not match the transfer",
                        )
                    }
                    artifact.file
                }
            return inspectArchives(files)
        } finally {
            claimed.forEach { (_, artifact) ->
                if (deleteInspectionFile(artifact.file)) {
                    releaseInspectionCapacity(artifact.sizeBytes)
                }
            }
        }
    }

    /** Deletes completed inspection artifacts that have exceeded their cache lifetime. */
    fun expireInspectionArtifacts() {
        val now = clockMillis()
        completedForInspection.entries.forEach { (transferId, artifact) ->
            if (
                now >= artifact.completedAtMillis &&
                    now - artifact.completedAtMillis >= inspectionMaxAgeMillis &&
                    completedForInspection.remove(transferId, artifact)
            ) {
                if (deleteInspectionFile(artifact.file)) {
                    releaseInspectionCapacity(artifact.sizeBytes)
                }
            }
        }
    }

    /** Removes cache files left by a previous Store Agent process before serving connections. */
    fun cleanupStaleInspectionFiles() {
        synchronized(inspectionCapacityLock) {
            check(
                active.values.none { it.inspectionFile != null } &&
                    completedForInspection.isEmpty() &&
                    reservedInspectionArtifacts == 0
            ) {
                "inspection cache cleanup requires an idle transfer service"
            }
            if (Files.isSymbolicLink(inspectionDirectory.toPath())) {
                if (!inspectionDirectory.delete()) {
                    throw IOException("the stale inspection cache could not be removed")
                }
                reservedInspectionBytes = 0L
                return
            }
            if (inspectionDirectory.exists() && !inspectionDirectory.isDirectory) {
                if (!inspectionDirectory.delete()) {
                    throw IOException("the stale inspection cache could not be removed")
                }
                reservedInspectionBytes = 0L
                return
            }
            val entries =
                if (inspectionDirectory.exists()) {
                    inspectionDirectory.listFiles()
                        ?: throw IOException("the stale inspection cache could not be listed")
                } else {
                    emptyArray()
                }
            entries.forEach { entry ->
                if (!deleteRecursivelyWithoutFollowingLinks(entry) && entry.exists()) {
                    throw IOException("the stale inspection cache could not be removed")
                }
            }
            reservedInspectionBytes = 0L
        }
    }

    fun closeControlSession(controlSessionId: String) {
        active.values
            .filter { it.controlSessionId == controlSessionId }
            .forEach { abort(it.transferId) }
        val orphanedInspection =
            completedForInspection.entries.filter { it.value.controlSessionId == controlSessionId }
        orphanedInspection.forEach { entry ->
            val artifact = entry.value
            if (completedForInspection.remove(entry.key, artifact)) {
                if (deleteInspectionFile(artifact.file)) {
                    releaseInspectionCapacity(artifact.sizeBytes)
                }
            }
        }
    }

    fun closeAll() {
        active.keys.toList().forEach(::abort)
        completedForInspection.entries.forEach { (transferId, artifact) ->
            if (completedForInspection.remove(transferId, artifact)) {
                if (deleteInspectionFile(artifact.file)) {
                    releaseInspectionCapacity(artifact.sizeBytes)
                }
            }
        }
        runCatching { cleanupStaleInspectionFiles() }
    }

    private fun begin(
        transferId: Long,
        begin: BulkBegin,
        controlSessionId: String,
    ): BulkAck? {
        expireInspectionArtifacts()
        if (transferId <= 0L || transferId and 1L != 0L) return rejected()
        if (begin.kind != io.apkrun.guest.protocol.v1.BulkKind.BULK_KIND_INSTALL_ARTIFACT) {
            return rejected()
        }
        if (begin.size <= 0L || begin.size > MAXIMUM_TRANSFER_BYTES) {
            return tooLarge()
        }
        if (
            begin.name.isBlank() ||
                begin.name.length > MAXIMUM_NAME_LENGTH ||
                begin.name == "." ||
                begin.name == ".." ||
                begin.name.contains('/') ||
                begin.name.contains('\\') ||
                begin.name.any(Char::isISOControl)
        ) {
            return rejected()
        }
        if (begin.context != INSPECT_CONTEXT && begin.context.isBlank()) return rejected()
        if (completedForInspection.containsKey(transferId) || active.containsKey(transferId)) {
            return rejected()
        }
        val beginDigest = if (begin.hasSha256()) begin.sha256.toByteArray() else null
        if (beginDigest != null && beginDigest.size != SHA256_BYTES) return rejected()
        if (!activeTransferSlots.tryAcquire()) return rejected()
        var slotOwnedByActiveTransfer = false
        val isInspection = begin.context == INSPECT_CONTEXT
        try {
            if (isInspection && !reserveInspectionCapacity(begin.size)) return rejected()
            var inspectionFile: File? = null
            val transfer =
                try {
                    if (isInspection) {
                        val file =
                            newTemporaryFile(transferId, begin.name).also { inspectionFile = it }
                        Transfer(
                            transferId = transferId,
                            controlSessionId = controlSessionId,
                            context = begin.context,
                            name = begin.name,
                            expectedSize = begin.size,
                            declaredDigest = beginDigest,
                            output = file.outputStream(),
                            inspectionFile = file,
                            inspectionReservationHeld = true,
                        )
                    } else {
                        val writer =
                            openInstallArtifact(
                                controlSessionId,
                                begin.context,
                                begin.name,
                                begin.size,
                                beginDigest,
                            )
                        Transfer(
                            transferId = transferId,
                            controlSessionId = controlSessionId,
                            context = begin.context,
                            name = begin.name,
                            expectedSize = begin.size,
                            declaredDigest = beginDigest,
                            output = writer.output,
                            installWriter = writer,
                        )
                    }
                } catch (error: StoreFailure) {
                    inspectionFile?.delete()
                    if (isInspection && deleteInspectionFile(inspectionFile)) {
                        releaseInspectionCapacity(begin.size)
                    }
                    return rejected()
                } catch (error: IOException) {
                    if (isInspection && deleteInspectionFile(inspectionFile)) {
                        releaseInspectionCapacity(begin.size)
                    }
                    AgentLog.warning("could not open a Store Agent artifact transfer")
                    return rejected()
                } catch (error: RuntimeException) {
                    if (isInspection && deleteInspectionFile(inspectionFile)) {
                        releaseInspectionCapacity(begin.size)
                    }
                    throw error
                }
            return if (active.putIfAbsent(transferId, transfer) == null) {
                slotOwnedByActiveTransfer = true
                null
            } else {
                runCatching { transfer.output.close() }
                if (deleteInspectionFile(transfer.inspectionFile)) {
                    releaseInspectionReservation(transfer)
                }
                transfer.installWriter?.finish(false, ByteArray(0), 0L)
                rejected()
            }
        } finally {
            if (!slotOwnedByActiveTransfer) activeTransferSlots.release()
        }
    }

    private fun reserveInspectionCapacity(sizeBytes: Long): Boolean =
        synchronized(inspectionCapacityLock) {
            if (
                reservedInspectionArtifacts >= maxInspectionArtifacts ||
                    sizeBytes > maxInspectionBytes - reservedInspectionBytes
            ) {
                return@synchronized false
            }
            reservedInspectionArtifacts += 1
            reservedInspectionBytes += sizeBytes
            true
        }

    private fun releaseInspectionCapacity(sizeBytes: Long) {
        synchronized(inspectionCapacityLock) {
            reservedInspectionArtifacts = (reservedInspectionArtifacts - 1).coerceAtLeast(0)
            reservedInspectionBytes = (reservedInspectionBytes - sizeBytes).coerceAtLeast(0L)
        }
    }

    private fun releaseInspectionReservation(transfer: Transfer) {
        synchronized(inspectionCapacityLock) {
            if (transfer.inspectionReservationHeld) {
                transfer.inspectionReservationHeld = false
                reservedInspectionArtifacts = (reservedInspectionArtifacts - 1).coerceAtLeast(0)
                reservedInspectionBytes =
                    (reservedInspectionBytes - transfer.expectedSize).coerceAtLeast(0L)
            }
        }
    }

    private fun deleteInspectionFile(file: File?): Boolean {
        if (file == null || !file.exists()) return true
        if (file.delete()) return true
        AgentLog.warning("could not remove a Store Agent inspection artifact")
        return false
    }

    private fun deleteRecursivelyWithoutFollowingLinks(file: File): Boolean {
        if (Files.isSymbolicLink(file.toPath())) {
            return file.delete()
        }
        if (!file.isDirectory) {
            return !file.exists() || file.delete()
        }
        val children = file.listFiles() ?: return false
        return children.all(::deleteRecursivelyWithoutFollowingLinks) &&
            (!file.exists() || file.delete())
    }

    private fun writeChunk(transferId: Long, bytes: ByteArray): BulkAck? {
        val transfer = active[transferId] ?: return rejected()
        if (bytes.isEmpty() || bytes.size > MAXIMUM_CHUNK_BYTES) {
            abort(transferId)
            return rejected()
        }
        synchronized(transfer) {
            if (transfer.ended) {
                abort(transferId)
                return rejected()
            }
            if (transfer.bytesWritten > transfer.expectedSize - bytes.size) {
                abort(transferId)
                return tooLarge()
            }
            try {
                transfer.output.write(bytes)
                transfer.digest.update(bytes)
                transfer.bytesWritten += bytes.size
            } catch (_: IOException) {
                abort(transferId)
                return rejected()
            }
        }
        return null
    }

    private fun end(transferId: Long, endDigest: ByteArray): BulkAck {
        val transfer = active.remove(transferId) ?: return rejected()
        try {
            synchronized(transfer) {
                if (transfer.ended) return rejected()
                transfer.ended = true
                val computed = transfer.digest.digest()
                val digestMatchesEnd =
                    if (transfer.declaredDigest == null) {
                        endDigest.size == SHA256_BYTES && computed.contentEquals(endDigest)
                    } else {
                        endDigest.isEmpty() && computed.contentEquals(transfer.declaredDigest)
                    }
                val complete =
                    transfer.bytesWritten == transfer.expectedSize &&
                        digestMatchesEnd &&
                        (transfer.declaredDigest == null ||
                            computed.contentEquals(transfer.declaredDigest))
                if (!complete) {
                    transfer.installWriter?.finish(false, computed, transfer.bytesWritten)
                    if (transfer.installWriter == null) {
                        runCatching { transfer.output.close() }
                    }
                    if (deleteInspectionFile(transfer.inspectionFile)) {
                        releaseInspectionReservation(transfer)
                    }
                    return hashMismatch()
                }
                if (transfer.installWriter != null) {
                    transfer.installWriter.finish(true, computed, transfer.bytesWritten)
                } else {
                    runCatching { transfer.output.flush() }
                    runCatching { transfer.output.close() }
                }
                val inspectedFile = transfer.inspectionFile
                if (inspectedFile != null) {
                    val completed =
                        CompletedArtifact(
                            controlSessionId = transfer.controlSessionId,
                            context = transfer.context,
                            name = transfer.name,
                            file = inspectedFile,
                            sizeBytes = transfer.expectedSize,
                            completedAtMillis = clockMillis(),
                        )
                    if (
                        completedForInspection.putIfAbsent(transfer.transferId, completed) != null
                    ) {
                        if (deleteInspectionFile(inspectedFile)) {
                            releaseInspectionReservation(transfer)
                        }
                        return rejected()
                    }
                    transfer.inspectionReservationHeld = false
                }
                return ok()
            }
        } finally {
            activeTransferSlots.release()
        }
    }

    private fun abort(transferId: Long) {
        val transfer = active.remove(transferId) ?: return
        try {
            synchronized(transfer) {
                if (transfer.ended) return
                transfer.ended = true
                runCatching { transfer.output.close() }
                transfer.installWriter?.finish(false, ByteArray(0), transfer.bytesWritten)
                if (deleteInspectionFile(transfer.inspectionFile)) {
                    releaseInspectionReservation(transfer)
                }
            }
        } finally {
            activeTransferSlots.release()
        }
    }

    private fun newTemporaryFile(transferId: Long, name: String): File {
        if (!inspectionDirectory.exists() && !inspectionDirectory.mkdirs()) {
            throw IOException("the inspection cache could not be created")
        }
        val safeName = name.replace(Regex("[^A-Za-z0-9_.-]"), "_")
        return File(
                inspectionDirectory,
                "$transferId-${temporarySequence.incrementAndGet()}-$safeName",
            )
            .also { file ->
                if (!file.createNewFile()) {
                    throw IOException("the inspection artifact could not be created")
                }
            }
    }

    private fun ack(status: BulkAckStatus): BulkAck = BulkAck.newBuilder().setStatus(status).build()

    private fun ok() = ack(BulkAckStatus.BULK_ACK_STATUS_OK)

    private fun hashMismatch() = ack(BulkAckStatus.BULK_ACK_STATUS_HASH_MISMATCH)

    private fun tooLarge() = ack(BulkAckStatus.BULK_ACK_STATUS_TOO_LARGE)

    private fun rejected() = ack(BulkAckStatus.BULK_ACK_STATUS_REJECTED)

    private data class CompletedArtifact(
        val controlSessionId: String,
        val context: String,
        val name: String,
        val file: File,
        val sizeBytes: Long,
        val completedAtMillis: Long,
    )

    private class Transfer(
        val transferId: Long,
        val controlSessionId: String,
        val context: String,
        val name: String,
        val expectedSize: Long,
        val declaredDigest: ByteArray?,
        val output: OutputStream,
        val inspectionFile: File? = null,
        val installWriter: InstallArtifactWriter? = null,
        var inspectionReservationHeld: Boolean = false,
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256"),
        var bytesWritten: Long = 0,
        var ended: Boolean = false,
    )

    private companion object {
        const val INSPECT_CONTEXT = "inspect"
        const val MAXIMUM_ACTIVE_TRANSFERS = 4
        const val MAXIMUM_TRANSFER_BYTES = 2L * 1024 * 1024 * 1024
        const val MAXIMUM_CHUNK_BYTES = 1024 * 1024
        const val MAXIMUM_NAME_LENGTH = 255
        const val SHA256_BYTES = 32
        const val MAXIMUM_INSPECTION_ARTIFACTS = 128
        const val MAXIMUM_INSPECTION_BYTES = 8L * 1024 * 1024 * 1024
        const val INSPECTION_MAX_AGE_MILLIS = 10 * 60 * 1_000L
    }
}

internal typealias InstallArtifactOpener =
    (
        controlSessionId: String,
        installId: String,
        name: String,
        size: Long,
        declaredSha256: ByteArray?,
    ) -> InstallArtifactWriter

private data class Configuration(
    val inspectionDirectory: File,
    val inspectArchives: (List<File>) -> ArchiveInfo,
    val openInstallArtifact: InstallArtifactOpener,
    val maxConcurrentTransfers: Int,
    val maxInspectionArtifacts: Int,
    val maxInspectionBytes: Long,
    val inspectionMaxAgeMillis: Long,
    val clockMillis: () -> Long,
)
