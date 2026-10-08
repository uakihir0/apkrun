package io.apkrun.guest.protocol

import io.apkrun.guest.protocol.v1.Envelope
import java.io.File
import kotlin.reflect.KClass
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The golden frames that the Swift tests share (guest-protocol.md §16). */
private object GoldenFrames {
    /** Gradle runs the unit tests in Guest/protocol, so the frames are two levels up. */
    val directory: File = File("../../Packages/GuestProtocol/testdata/frames").canonicalFile

    fun names(prefix: String): List<String> =
        directory
            .listFiles { file -> file.name.startsWith(prefix) && file.name.endsWith(".bin") }
            .orEmpty()
            .map { it.name.removeSuffix(".bin") }
            .sorted()

    fun frame(name: String): ByteArray = File(directory, "$name.bin").readBytes()
}

private val requiredBodyKinds =
    setOf(
        Envelope.BodyCase.HELLO,
        Envelope.BodyCase.HELLO_ACK,
        Envelope.BodyCase.REQUEST,
        Envelope.BodyCase.RESPONSE,
        Envelope.BodyCase.EVENT,
        Envelope.BodyCase.CANCEL,
        Envelope.BodyCase.INPUT_BATCH,
        Envelope.BodyCase.INPUT_ACK,
        Envelope.BodyCase.IME_COMMAND,
        Envelope.BodyCase.IME_STATE,
        Envelope.BodyCase.BULK,
    )

private val expectedFailures: Map<String, KClass<out GuestProtocolFailure>> =
    mapOf(
        "invalid-zero-length" to GuestProtocolFailure.MalformedFrame::class,
        "invalid-oversize" to GuestProtocolFailure.FrameTooLarge::class,
        "invalid-truncated" to GuestProtocolFailure.MalformedFrame::class,
        "invalid-malformed" to GuestProtocolFailure.MalformedFrame::class,
    )

/** Runs [block], which must throw a failure of type [T], and returns that failure. */
private inline fun <reified T : GuestProtocolFailure> failureOf(block: () -> Unit): T {
    try {
        block()
    } catch (failure: GuestProtocolFailure) {
        if (failure is T) {
            return failure
        }
        throw AssertionError("expected ${T::class.simpleName}, got $failure", failure)
    }
    throw AssertionError("expected ${T::class.simpleName}, but nothing was thrown")
}

class FrameCodecTest {
    @Test
    fun `golden valid frames decode and re-encode byte for byte`() {
        val names = GoldenFrames.names("valid-")
        assertTrue(names.size >= requiredBodyKinds.size)
        for (name in names) {
            val frame = GoldenFrames.frame(name)
            val envelope = FrameCodec.decode(frame)
            assertArrayEquals(
                "$name does not re-encode to the same bytes",
                frame,
                FrameCodec.encode(envelope),
            )
        }
    }

    @Test
    fun `golden valid frames cover every envelope body kind`() {
        val covered =
            GoldenFrames.names("valid-")
                .map { FrameCodec.decode(GoldenFrames.frame(it)).bodyCase }
                .toSet()
        assertTrue(
            "missing body kinds: ${requiredBodyKinds - covered}",
            covered.containsAll(requiredBodyKinds),
        )
    }

    @Test
    fun `invalid golden frames fail with their typed error`() {
        assertEquals(expectedFailures.keys, GoldenFrames.names("invalid-").toSet())
        for ((name, expected) in expectedFailures) {
            val frame = GoldenFrames.frame(name)
            val failure =
                try {
                    FrameCodec.decode(frame)
                    throw AssertionError("$name decoded, but it must be rejected")
                } catch (failure: GuestProtocolFailure) {
                    failure
                }
            assertEquals("$name failed with $failure", expected, failure::class)
        }
    }

    @Test
    fun `encoding rejects empty and oversize bodies`() {
        failureOf<GuestProtocolFailure.MalformedFrame> { FrameCodec.frame(ByteArray(0)) }
        failureOf<GuestProtocolFailure.FrameTooLarge> {
            FrameCodec.frame(ByteArray(FrameCodec.MAXIMUM_BODY_SIZE + 1))
        }
        assertEquals(
            FrameCodec.LENGTH_PREFIX_SIZE + FrameCodec.MAXIMUM_BODY_SIZE,
            FrameCodec.frame(ByteArray(FrameCodec.MAXIMUM_BODY_SIZE)).size,
        )
        // An envelope with no fields serializes to zero bytes, which is not a valid body.
        failureOf<GuestProtocolFailure.MalformedFrame> {
            FrameCodec.encode(Envelope.getDefaultInstance())
        }
    }

    @Test
    fun `the length prefix is big-endian and counts only the body`() {
        val frame = FrameCodec.frame(ByteArray(0x0102))
        assertArrayEquals(byteArrayOf(0, 0, 1, 2), frame.copyOfRange(0, 4))
        assertEquals(4 + 0x0102, frame.size)
    }

    @Test
    fun `the frame decoder reassembles every valid frame from single bytes`() {
        val frames = GoldenFrames.names("valid-").map { GoldenFrames.frame(it) }
        val stream = frames.fold(ByteArray(0)) { acc, frame -> acc + frame }
        val expectedBodies = frames.map { it.copyOfRange(FrameCodec.LENGTH_PREFIX_SIZE, it.size) }

        val decoder = FrameDecoder()
        val bodies = mutableListOf<ByteArray>()
        for (byte in stream) {
            decoder.append(byteArrayOf(byte))
            while (true) {
                bodies += decoder.nextBody() ?: break
            }
        }
        assertEquals(expectedBodies.size, bodies.size)
        bodies.zip(expectedBodies).forEach { (actual, expected) ->
            assertArrayEquals(expected, actual)
        }
        assertEquals(0, decoder.pendingByteCount)
    }

    @Test(timeout = 20_000)
    fun `the frame decoder reads many small frames from one buffer in linear time`() {
        // 200 000 frames of 100 bytes arrive in one append, a 20 MB buffer. Copying the rest of the
        // buffer for each frame would copy about 2 TB, far beyond the timeout.
        val frame = FrameCodec.frame(ByteArray(96))
        val count = 200_000
        val stream = ByteArray(frame.size * count)
        for (index in 0 until count) {
            frame.copyInto(stream, index * frame.size)
        }
        val decoder = FrameDecoder()
        decoder.append(stream)
        var bodies = 0
        while (decoder.nextBody() != null) {
            bodies++
        }
        assertEquals(count, bodies)
        assertEquals(0, decoder.pendingByteCount)
    }

    @Test
    fun `the frame decoder rejects an oversize length before the body arrives`() {
        val decoder = FrameDecoder()
        decoder.append(byteArrayOf(0x00, 0x40, 0x00, 0x01))
        failureOf<GuestProtocolFailure.FrameTooLarge> { decoder.nextBody() }
    }

    @Test
    fun `decode rejects trailing bytes after the frame`() {
        val frame = GoldenFrames.frame("valid-cancel") + byteArrayOf(0)
        failureOf<GuestProtocolFailure.MalformedFrame> { FrameCodec.decode(frame) }
    }

    @Test
    fun `the frame decoder waits for the whole body`() {
        val decoder = FrameDecoder()
        decoder.append(byteArrayOf(0, 0, 0, 10, 1, 2, 3, 4, 5))
        assertNull(decoder.nextBody())
        assertEquals(9, decoder.pendingByteCount)
    }
}
