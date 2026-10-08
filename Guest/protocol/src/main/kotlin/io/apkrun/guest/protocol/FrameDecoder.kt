package io.apkrun.guest.protocol

/**
 * Reassembles frames from a byte stream (guest-protocol.md §4). Append the bytes as they arrive,
 * and take each body when it is complete. A bad length fails as soon as its 4 prefix bytes are
 * present, so a body above the limit is never waited for or buffered.
 */
class FrameDecoder {
    private var buffer = ByteArray(0)

    /** Bytes that have arrived but are not yet returned as a body. */
    val pendingByteCount: Int
        get() = buffer.size

    /** Adds bytes from the connection. */
    fun append(bytes: ByteArray) {
        buffer += bytes
    }

    /**
     * Returns the body of the next complete frame, or null when more bytes are needed. Throws a
     * [GuestProtocolFailure] when the length of the next frame is invalid.
     */
    fun nextBody(): ByteArray? {
        if (buffer.size < FrameCodec.LENGTH_PREFIX_SIZE) {
            return null
        }
        val length = FrameCodec.bodyLength(buffer.copyOfRange(0, FrameCodec.LENGTH_PREFIX_SIZE))
        val frameSize = FrameCodec.LENGTH_PREFIX_SIZE + length
        if (buffer.size < frameSize) {
            return null
        }
        val body = buffer.copyOfRange(FrameCodec.LENGTH_PREFIX_SIZE, frameSize)
        buffer = buffer.copyOfRange(frameSize, buffer.size)
        return body
    }
}
