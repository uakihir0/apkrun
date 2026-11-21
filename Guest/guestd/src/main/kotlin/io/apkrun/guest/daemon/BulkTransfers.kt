package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.v1.BulkAbort
import io.apkrun.guest.protocol.v1.BulkBegin
import io.apkrun.guest.protocol.v1.BulkEnd
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.BulkKind
import io.apkrun.guest.runtime.AgentLog
import java.io.InputStream
import java.security.MessageDigest

/**
 * Sends payloads on the agent's bulk connection (guest-protocol.md §10). Transfers the agent
 * announces — diagnostics items today — get odd transfer IDs, and their begin, chunks, and end
 * frames go to the one open bulk connection. A send while no bulk connection is open reports
 * failure instead of queueing, so the announcing reply and the frames never disagree.
 */
class BulkTransfers : ClipboardBridge.BulkImageSender {
    private val lock = Any()

    /** The open bulk connections, newest first; sends go to the newest. */
    private val writers = ArrayDeque<FrameWriter>()
    private var nextTransferId = 1L

    /** Makes [writer] the bulk connection's sink until [detach]. Only one is kept. */
    fun attach(writer: FrameWriter) {
        synchronized(lock) {
            writers.remove(writer)
            writers.addFirst(writer)
        }
    }

    /** Stops sending on [writer]; an older connection becomes the sink again. */
    fun detach(writer: FrameWriter) {
        synchronized(lock) {
            writers.remove(writer)
        }
    }

    /**
     * Sends [payload] as a [BulkKind.BULK_KIND_DIAGNOSTICS_ITEM] transfer and returns its transfer
     * ID, or `null` when no bulk connection is open. The frames are whole before this returns.
     */
    fun sendDiagnosticsItem(name: String, mimeType: String, payload: ByteArray): Long? =
        send(BulkKind.BULK_KIND_DIAGNOSTICS_ITEM, name, mimeType, payload)

    /**
     * Sends PNG bytes as a [BulkKind.BULK_KIND_CLIPBOARD_IMAGE] transfer and returns its transfer
     * ID, or `null` when no bulk connection is open.
     */
    override fun sendClipboardImage(png: ByteArray): Long? =
        send(BulkKind.BULK_KIND_CLIPBOARD_IMAGE, "clip.png", "image/png", png)

    /**
     * Sends [payload] as a transfer of [kind] and returns its transfer ID, or `null` when no bulk
     * connection is open. The frames are whole before this returns.
     */
    fun send(kind: BulkKind, name: String, mimeType: String, payload: ByteArray): Long? {
        val digest = MessageDigest.getInstance("SHA-256").digest(payload)
        synchronized(lock) {
            val target = writers.firstOrNull() ?: return null
            val transferId = nextTransferId
            nextTransferId += 2
            target.send { envelope ->
                envelope.bulk =
                    BulkFrame.newBuilder()
                        .setTransferId(transferId)
                        .setBegin(
                            BulkBegin.newBuilder()
                                .setKind(kind)
                                .setName(name)
                                .setMimeType(mimeType)
                                .setSize(payload.size.toLong())
                                .setSha256(com.google.protobuf.ByteString.copyFrom(digest))
                        )
                        .build()
            }
            var offset = 0
            while (offset < payload.size) {
                val end = minOf(offset + CHUNK_BYTES, payload.size)
                val chunk = payload.copyOfRange(offset, end)
                offset = end
                target.send { envelope ->
                    envelope.bulk =
                        BulkFrame.newBuilder()
                            .setTransferId(transferId)
                            .setChunk(com.google.protobuf.ByteString.copyFrom(chunk))
                            .build()
                }
            }
            target.send { envelope ->
                envelope.bulk =
                    BulkFrame.newBuilder()
                        .setTransferId(transferId)
                        .setEnd(
                            BulkEnd.newBuilder()
                                .setSha256(com.google.protobuf.ByteString.copyFrom(digest))
                        )
                        .build()
            }
            return transferId
        }
    }

    /**
     * Streams [input] as a transfer of [kind] and returns its transfer ID, or `null` when no bulk
     * connection is open. Unlike [send] the payload never lands in memory whole: chunks of
     * [CHUNK_BYTES] are framed as they are read and the digest is computed on the way. [size] is
     * the announced total, or -1 when unknown.
     */
    fun sendStream(
        kind: BulkKind,
        name: String,
        mimeType: String,
        size: Long,
        input: InputStream,
    ): Long? {
        val digest = MessageDigest.getInstance("SHA-256")
        synchronized(lock) {
            val target = writers.firstOrNull() ?: return null.also { input.close() }
            val transferId = nextTransferId
            nextTransferId += 2
            var began = false
            try {
                input.use { stream ->
                    target.send { envelope ->
                        envelope.bulk =
                            BulkFrame.newBuilder()
                                .setTransferId(transferId)
                                .setBegin(
                                    BulkBegin.newBuilder()
                                        .setKind(kind)
                                        .setName(name)
                                        .setMimeType(mimeType)
                                        .setSize(if (size < 0) 0 else size)
                                )
                                .build()
                    }
                    began = true
                    val buffer = ByteArray(CHUNK_BYTES)
                    while (true) {
                        val read = stream.read(buffer)
                        if (read <= 0) break
                        digest.update(buffer, 0, read)
                        target.send { envelope ->
                            envelope.bulk =
                                BulkFrame.newBuilder()
                                    .setTransferId(transferId)
                                    .setChunk(
                                        com.google.protobuf.ByteString.copyFrom(buffer, 0, read)
                                    )
                                    .build()
                        }
                    }
                    target.send { envelope ->
                        envelope.bulk =
                            BulkFrame.newBuilder()
                                .setTransferId(transferId)
                                .setEnd(
                                    BulkEnd.newBuilder()
                                        .setSha256(
                                            com.google.protobuf.ByteString.copyFrom(digest.digest())
                                        )
                                )
                                .build()
                    }
                }
            } catch (error: Exception) {
                AgentLog.warning("a bulk stream failed: ${error.javaClass.simpleName}")
                if (began) {
                    // Tell the host to drop the partial assembly so its temp
                    // file and handle do not linger (bulk.proto abort).
                    try {
                        target.send { envelope ->
                            envelope.bulk =
                                BulkFrame.newBuilder()
                                    .setTransferId(transferId)
                                    .setAbort(BulkAbort.newBuilder().setReason("send failed"))
                                    .build()
                        }
                    } catch (abortError: Exception) {
                        AgentLog.warning("a bulk abort failed: ${abortError.javaClass.simpleName}")
                    }
                }
                return null
            }
            return transferId
        }
    }

    companion object {
        /** The chunk limit of the bulk protocol (guest-protocol.md §10). */
        const val CHUNK_BYTES = 1 * 1024 * 1024
    }
}
