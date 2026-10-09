package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.GuestError
import io.apkrun.guest.protocol.v1.GuestErrorCode

/**
 * A failure of one operation. It becomes the GuestError of the response (guest-protocol.md §12.1).
 * The message is English and carries no user data, and [detail] holds the extra context of the
 * error.
 */
class GuestFailure(
    val code: GuestErrorCode,
    message: String,
    val detail: Map<String, String> = emptyMap(),
) : RuntimeException(message) {
    /** The wire form of this failure. */
    fun toGuestError(): GuestError =
        GuestError.newBuilder()
            .setCode(code)
            .setMessage(message.orEmpty())
            .putAllDetail(detail)
            .build()
}
