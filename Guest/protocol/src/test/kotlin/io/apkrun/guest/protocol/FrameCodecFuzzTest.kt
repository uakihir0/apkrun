package io.apkrun.guest.protocol

import com.code_intelligence.jazzer.api.FuzzedDataProvider
import com.code_intelligence.jazzer.junit.FuzzTest

/**
 * `guest-frame-kotlin` (test-strategy.md §7.2, #92): the wire decoder fed arbitrary bytes must fail
 * with typed errors, never throw unchecked or hang. Run: `./gradlew :protocol:test --tests
 * '*FrameCodecFuzzTest*'` with Jazzer.
 */
class FrameCodecFuzzTest {
    @FuzzTest
    fun decodeFrame(data: FuzzedDataProvider) {
        val bytes = data.consumeRemainingAsBytes()
        runCatching { FrameCodec.decode(bytes) }
        // Also walk the streaming decoder so partial-frame paths run.
        val decoder = FrameDecoder()
        var offset = 0
        while (offset < bytes.size) {
            val chunkSize = minOf(bytes.size - offset, bytes[offset].toInt().and(0xff) + 1)
            runCatching {
                decoder.append(bytes.copyOfRange(offset, offset + chunkSize))
            }
            offset += chunkSize
            runCatching { decoder.nextBody() }
        }
    }

    @FuzzTest
    fun decodeBody(data: FuzzedDataProvider) {
        runCatching { FrameCodec.decodeBody(data.consumeRemainingAsBytes()) }
    }
}
