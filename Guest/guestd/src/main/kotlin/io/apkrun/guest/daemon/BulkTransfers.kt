package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.v1.BulkBegin
import io.apkrun.guest.protocol.v1.BulkEnd
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.BulkKind
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

    companion object {
        /** The chunk limit of the bulk protocol (guest-protocol.md §10). */
        const val CHUNK_BYTES = 1 * 1024 * 1024
    }
}
