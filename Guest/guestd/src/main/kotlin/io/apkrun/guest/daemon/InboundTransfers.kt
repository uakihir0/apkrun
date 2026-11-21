package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.BulkKind
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * Reassembles host-announced bulk transfers (guest-protocol.md §10): `SetClipboard` names a
 * `transfer_id` on its image, and the frames arrive on the bulk connection. Finished payloads land
 * as files under `cacheDir/transfers/` so the clipboard bridge can hand their URI to Android; a
 * consumer takes a file once, then the file is deleted.
 */
class InboundTransfers(private val directory: File) {

    private class Assembly(
        val file: File,
        val stream: FileOutputStream,
        val cap: Long,
        var received: Long = 0,
    )

    private val assemblies = ConcurrentHashMap<Long, Assembly>()
    private val completed = ConcurrentHashMap<Long, File>()

    /** Feeds one received frame into the assemblies. */
    fun accept(frame: BulkFrame) {
        val id = frame.transferId
        when {
            frame.hasBegin() -> {
                val file = File(directory, "in-$id")
                directory.mkdirs()
                // The cap depends on what the host is sending: clipboard images stay at 16 MiB,
                // while file drops and exports follow the 2 GiB of bulk.proto §10.
                val cap =
                    when (frame.begin.kind) {
                        BulkKind.BULK_KIND_CLIPBOARD_IMAGE -> CAP_CLIPBOARD_BYTES
                        else -> CAP_BYTES
                    }
                assemblies[id] = Assembly(file, FileOutputStream(file), cap)
            }
            frame.hasChunk() -> {
                assemblies[id]?.let { assembly ->
                    val chunk = frame.chunk.toByteArray()
                    assembly.stream.write(chunk)
                    assembly.received += chunk.size
                    if (assembly.received > assembly.cap) {
                        drop(id)
                    }
                }
            }
            frame.hasEnd() -> {
                assemblies.remove(id)?.let { assembly ->
                    assembly.stream.close()
                    completed[id] = assembly.file
                }
            }
            frame.hasAbort() -> drop(id)
            else -> Unit
        }
    }

    /** The file of a finished transfer, deleted once taken, or `null`. */
    fun take(transferId: Long): File? {
        val file = completed.remove(transferId) ?: return null
        return if (file.exists()) file else null
    }

    /** Whether a finished transfer waits for its consumer. */
    fun isComplete(transferId: Long): Boolean = completed.containsKey(transferId)

    private fun drop(transferId: Long) {
        assemblies.remove(transferId)?.let { assembly ->
            runCatching { assembly.stream.close() }
            assembly.file.delete()
        }
    }

    companion object {
        /** A clipboard image is at most 16 MiB (runtime-api.md §11.4). */
        private const val CAP_CLIPBOARD_BYTES: Long = 16L * 1024 * 1024

        /** Every other transfer follows the 2 GiB bulk limit (bulk.proto §10). */
        private const val CAP_BYTES: Long = 2L * 1024 * 1024 * 1024
    }
}
