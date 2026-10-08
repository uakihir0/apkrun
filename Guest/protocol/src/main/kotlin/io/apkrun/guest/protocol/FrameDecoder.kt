package io.apkrun.guest.protocol

/**
 * Reassembles frames from a byte stream (guest-protocol.md §4). Append the bytes as they arrive,
 * and take each body when it is complete. A bad length fails as soon as its 4 prefix bytes are
 * present, so a body above the limit is never waited for or buffered.
 *
 * The decoder keeps a read index and a write index instead of copying the rest of the buffer for
 * each frame. The consumed bytes are dropped when the buffer needs room, and the buffer grows by
 * doubling, so reading many frames from one buffer costs time proportional to the number of bytes.
 */
class FrameDecoder {
    private var buffer = ByteArray(INITIAL_CAPACITY)

    /** The index of the first byte that has not been returned as part of a body. */
    private var readIndex = 0

    /** The index just after the last byte that has arrived. */
    private var writeIndex = 0

    /** Bytes that have arrived but are not yet returned as a body. */
    val pendingByteCount: Int
        get() = writeIndex - readIndex

    /** Adds bytes from the connection. */
    fun append(bytes: ByteArray) {
        makeRoom(bytes.size)
        bytes.copyInto(buffer, writeIndex)
        writeIndex += bytes.size
    }

    /**
     * Returns the body of the next complete frame, or null when more bytes are needed. Throws a
     * [GuestProtocolFailure] when the length of the next frame is invalid.
     */
    fun nextBody(): ByteArray? {
        if (pendingByteCount < FrameCodec.LENGTH_PREFIX_SIZE) {
            return null
        }
        val prefixEnd = readIndex + FrameCodec.LENGTH_PREFIX_SIZE
        val length = FrameCodec.bodyLength(buffer.copyOfRange(readIndex, prefixEnd))
        val frameEnd = prefixEnd + length
        if (writeIndex < frameEnd) {
            return null
        }
        val body = buffer.copyOfRange(prefixEnd, frameEnd)
        readIndex = frameEnd
        return body
    }

    /**
     * Makes room for [extra] bytes after the write index. The consumed bytes are dropped first. The
     * buffer grows only when the pending bytes and the new bytes do not fit in the current one.
     */
    private fun makeRoom(extra: Int) {
        if (writeIndex + extra <= buffer.size) {
            return
        }
        val pending = pendingByteCount
        val capacity =
            if (pending + extra <= buffer.size) {
                buffer.size
            } else {
                maxOf(buffer.size * 2, pending + extra)
            }
        val target = if (capacity == buffer.size) buffer else ByteArray(capacity)
        buffer.copyInto(target, 0, readIndex, writeIndex)
        buffer = target
        readIndex = 0
        writeIndex = pending
    }

    private companion object {
        const val INITIAL_CAPACITY = 1024
    }
}
