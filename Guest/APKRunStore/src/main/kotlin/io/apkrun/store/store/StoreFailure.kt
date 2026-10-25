package io.apkrun.store.store

import io.apkrun.guest.protocol.v1.GuestError
import io.apkrun.guest.protocol.v1.GuestErrorCode

/** A typed error returned by a Store Agent operation. */
class StoreFailure(
    val code: GuestErrorCode,
    override val message: String,
    val detail: Map<String, String> = emptyMap(),
) : RuntimeException(message) {
    fun toGuestError(): GuestError =
        GuestError.newBuilder().setCode(code).setMessage(message).putAllDetail(detail).build()
}
