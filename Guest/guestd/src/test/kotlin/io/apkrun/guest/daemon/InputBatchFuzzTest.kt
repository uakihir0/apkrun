package io.apkrun.guest.daemon

import com.code_intelligence.jazzer.api.FuzzedDataProvider
import com.code_intelligence.jazzer.junit.FuzzTest
import io.apkrun.guest.protocol.v1.InputBatch
import io.apkrun.guest.protocol.v1.InputEvent

/**
 * `input-batch` (test-strategy.md §7.2, #92): InputBatch protobuf decode and the `InputValidator`
 * bounds every event passes before injection. Must never throw unchecked or hang on hostile bytes.
 */
class InputBatchFuzzTest {
    private val bounds = DisplayBounds(width = 1920, height = 1080)

    @FuzzTest
    fun decodeAndValidate(data: FuzzedDataProvider) {
        val bytes = data.consumeRemainingAsBytes()
        val batch = runCatching { InputBatch.parseFrom(bytes) }.getOrNull() ?: return
        // SECURITY: untrusted host input; every field is validated before
        // injection, matching the InputService.submit path.
        for (event: InputEvent in batch.eventsList) {
            InputValidator.isValid(event, bounds)
        }
    }
}
