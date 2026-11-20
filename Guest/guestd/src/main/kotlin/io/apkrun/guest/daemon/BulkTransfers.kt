package io.apkrun.guest.daemon

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
class BulkTransfers {
    private val lock = Any()
    private var writer: FrameWriter? = null
    private var nextTransferId = 1L

    /** Makes [writer] the bulk connection's sink until [detach]. Only one is kept. */
    fun attach(writer: FrameWriter) {
        synchronized(lock) {
            this.writer = writer
        }
    }

    /** Stops sending on [writer]. */
    fun detach(writer: FrameWriter) {
        synchronized(lock) {
            if (this.writer === writer) {
                this.writer = null
            }
        }
    }

    /**
     * Sends [payload] as a [BulkKind.BULK_KIND_DIAGNOSTICS_ITEM] transfer and returns its transfer
     * ID, or `null` when no bulk connection is open. The frames are whole before this returns.
     */
    fun sendDiagnosticsItem(name: String, mimeType: String, payload: ByteArray): Long? {
        val digest = MessageDigest.getInstance("SHA-256").digest(payload)
        synchronized(lock) {
            val target = writer ?: return null
            val transferId = nextTransferId
            nextTransferId += 2
            target.send { envelope ->
                envelope.bulk =
                    BulkFrame.newBuilder()
                        .setTransferId(transferId)
                        .setBegin(
                            BulkBegin.newBuilder()
                                .setKind(BulkKind.BULK_KIND_DIAGNOSTICS_ITEM)
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
