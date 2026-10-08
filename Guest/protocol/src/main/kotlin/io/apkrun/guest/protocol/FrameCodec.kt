package io.apkrun.guest.protocol

import com.google.protobuf.InvalidProtocolBufferException
import io.apkrun.guest.protocol.v1.Envelope

/**
 * Encodes and decodes the frames of the guest protocol (guest-protocol.md §4): a 4-byte big-endian
 * length, then one serialized [Envelope]. The length is at least 1 and at most [MAXIMUM_BODY_SIZE].
 * The codec is a pure function over bytes. The Swift codec shares its golden frames
 * (`Packages/GuestProtocol/testdata/frames`, §16).
 */
object FrameCodec {
    const val LENGTH_PREFIX_SIZE = 4

    /** The largest body that a frame can carry: 4 MiB. */
    const val MAXIMUM_BODY_SIZE = 4_194_304

    /** Encodes one envelope as a complete frame. */
    fun encode(envelope: Envelope): ByteArray = frame(envelope.toByteArray())

    /**
     * Wraps a serialized body in a frame. The body must be between 1 and [MAXIMUM_BODY_SIZE] bytes.
     */
    fun frame(body: ByteArray): ByteArray {
        validateBodyLength(body.size.toLong())
        val frame = ByteArray(LENGTH_PREFIX_SIZE + body.size)
        val length = body.size
        frame[0] = (length ushr 24).toByte()
        frame[1] = (length ushr 16).toByte()
        frame[2] = (length ushr 8).toByte()
        frame[3] = length.toByte()
        body.copyInto(frame, LENGTH_PREFIX_SIZE)
        return frame
    }

    /**
     * Decodes exactly one complete frame. Missing, extra, or undecodable bytes are a
     * [GuestProtocolFailure.MalformedFrame].
     */
    fun decode(frame: ByteArray): Envelope {
        if (frame.size < LENGTH_PREFIX_SIZE) {
            throw GuestProtocolFailure.MalformedFrame("the length prefix is incomplete")
        }
        val length = bodyLength(frame.copyOfRange(0, LENGTH_PREFIX_SIZE))
        if (frame.size != LENGTH_PREFIX_SIZE + length) {
            throw GuestProtocolFailure.MalformedFrame("the frame does not match its length")
        }
        return decodeBody(frame.copyOfRange(LENGTH_PREFIX_SIZE, frame.size))
    }

    /**
     * Reads the body length from the 4-byte prefix. A length of 0 or above [MAXIMUM_BODY_SIZE] is
     * rejected before any body is read or allocated.
     */
    fun bodyLength(prefix: ByteArray): Int {
        if (prefix.size != LENGTH_PREFIX_SIZE) {
            throw GuestProtocolFailure.MalformedFrame("the length prefix is incomplete")
        }
        val length = prefix.fold(0L) { value, byte -> (value shl 8) or (byte.toLong() and 0xFF) }
        validateBodyLength(length)
        return length.toInt()
    }

    /**
     * Parses a serialized body. Bytes that do not decode are a
     * [GuestProtocolFailure.MalformedFrame].
     */
    fun decodeBody(body: ByteArray): Envelope =
        try {
            Envelope.parseFrom(body)
        } catch (error: InvalidProtocolBufferException) {
            throw GuestProtocolFailure.MalformedFrame("the body does not decode as an Envelope")
        }

    private fun validateBodyLength(length: Long) {
        if (length == 0L) {
            throw GuestProtocolFailure.MalformedFrame("the length is zero")
        }
        if (length > MAXIMUM_BODY_SIZE) {
            throw GuestProtocolFailure.FrameTooLarge()
        }
    }
}
