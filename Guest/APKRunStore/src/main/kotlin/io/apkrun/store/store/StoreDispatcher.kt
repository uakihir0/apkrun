package io.apkrun.store.store

import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Pong
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Enforces the Store Agent capability table and maps supported operations to generated protobufs.
 */
class StoreDispatcher(
    private val operations: StoreOperations,
    private val uptimeMillis: () -> Long,
    private val defaultTimeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
) {
    private val active = ConcurrentHashMap<RequestKey, Deferred<Response?>>()
    private val cancelled = ConcurrentHashMap.newKeySet<RequestKey>()

    /**
     * Answers one request. The operation runs off the socket reader so the connection can receive
     * CANCEL and other requests while Android framework calls are waiting.
     */
    suspend fun dispatch(
        requestId: Long,
        request: Request,
        enabledCapabilities: Set<String>,
        controlSessionId: String,
    ): Response {
        val capability =
            requiredCapability(request.opCase)
                ?: return failure(
                    GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                    "this Store Agent build does not implement the requested operation",
                )
        if (capability !in enabledCapabilities) {
            return failure(
                GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                "the capability $capability is not enabled for this connection",
            )
        }

        val key = RequestKey(controlSessionId, requestId)
        val timeout =
            if (request.timeoutMs > 0) request.timeoutMs.toLong() else defaultTimeoutMillis
        try {
            // Cancelling the child leaves this caller alive to serialize the response frame.
            return coroutineScope {
                val work =
                    async(Dispatchers.IO) {
                        withTimeoutOrNull(timeout) {
                            runInterruptible { run(request, enabledCapabilities, controlSessionId) }
                        }
                    }
                active[key] = work
                work.await()
                    ?: failure(
                        GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT,
                        "the operation did not finish within $timeout ms",
                    )
            }
        } catch (error: CancellationException) {
            if (cancelled.remove(key)) {
                return failure(
                    GuestErrorCode.GUEST_ERROR_CODE_CANCELLED,
                    "the request was cancelled by the host",
                )
            }
            throw error
        } finally {
            active.remove(key)
            cancelled.remove(key)
        }
    }

    /** Cancels a live request without suppressing its eventual CANCELLED response. */
    fun cancel(controlSessionId: String, targetId: Long) {
        val key = RequestKey(controlSessionId, targetId)
        val work = active[key] ?: return
        cancelled.add(key)
        work.cancel()
    }

    private fun run(
        request: Request,
        enabledCapabilities: Set<String>,
        controlSessionId: String,
    ): Response =
        try {
            when (request.opCase) {
                Request.OpCase.PING ->
                    Response.newBuilder()
                        .setPing(
                            Pong.newBuilder()
                                .setNonce(request.ping.nonce)
                                .setGuestUptimeMs(uptimeMillis())
                        )
                        .build()
                Request.OpCase.INSPECT_ARCHIVE ->
                    Response.newBuilder()
                        .setInspectArchive(operations.inspectArchive(request.inspectArchive))
                        .build()
                Request.OpCase.BEGIN_INSTALL -> {
                    InstallRequestValidator.validate(
                        request.beginInstall,
                        enabledCapabilities,
                    )
                    Response.newBuilder()
                        .setBeginInstall(
                            operations.beginInstall(
                                request.beginInstall,
                                enabledCapabilities,
                                controlSessionId,
                            )
                        )
                        .build()
                }
                Request.OpCase.COMMIT_INSTALL -> {
                    operations.commitInstall(request.commitInstall, controlSessionId)
                    Response.newBuilder()
                        .setCommitInstall(io.apkrun.guest.protocol.v1.Empty.getDefaultInstance())
                        .build()
                }
                Request.OpCase.ABANDON_INSTALL -> {
                    operations.abandonInstall(request.abandonInstall, controlSessionId)
                    Response.newBuilder()
                        .setAbandonInstall(io.apkrun.guest.protocol.v1.Empty.getDefaultInstance())
                        .build()
                }
                Request.OpCase.UNINSTALL ->
                    Response.newBuilder()
                        .setUninstall(operations.uninstall(request.uninstall))
                        .build()
                Request.OpCase.GET_PACKAGE_METADATA ->
                    Response.newBuilder()
                        .setGetPackageMetadata(
                            operations.getPackageMetadata(request.getPackageMetadata)
                        )
                        .build()
                Request.OpCase.LIST_MANAGED_PACKAGES ->
                    Response.newBuilder()
                        .setListManagedPackages(
                            operations.listManagedPackages(request.listManagedPackages)
                        )
                        .build()
                else ->
                    failure(
                        GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                        "this Store Agent build does not implement the requested operation",
                    )
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw CancellationException("the Store Agent operation was interrupted").apply {
                initCause(error)
            }
        } catch (failure: StoreFailure) {
            Response.newBuilder().setError(failure.toGuestError()).build()
        } catch (error: SecurityException) {
            failure(
                GuestErrorCode.GUEST_ERROR_CODE_PERMISSION_DENIED,
                "Android refused the operation",
            )
        } catch (error: Exception) {
            failure(
                GuestErrorCode.GUEST_ERROR_CODE_INTERNAL,
                "the Store Agent operation failed",
                mapOf("exception" to error.javaClass.name),
            )
        }

    companion object {
        const val CORE_CAPABILITY = "core.v1"
        const val STORE_INSTALL_CAPABILITY = "store.install.v1"
        const val STORE_METADATA_CAPABILITY = "store.metadata.v1"
        const val DEFAULT_TIMEOUT_MILLIS = 5_000L

        fun requiredCapability(operation: Request.OpCase): String? =
            when (operation) {
                Request.OpCase.PING -> CORE_CAPABILITY
                Request.OpCase.INSPECT_ARCHIVE,
                Request.OpCase.GET_PACKAGE_METADATA,
                Request.OpCase.LIST_MANAGED_PACKAGES -> STORE_METADATA_CAPABILITY
                Request.OpCase.BEGIN_INSTALL,
                Request.OpCase.COMMIT_INSTALL,
                Request.OpCase.ABANDON_INSTALL,
                Request.OpCase.UNINSTALL -> STORE_INSTALL_CAPABILITY
                else -> null
            }
    }

    private data class RequestKey(val sessionId: String, val requestId: Long)

    private fun failure(
        code: GuestErrorCode,
        message: String,
        detail: Map<String, String> = emptyMap(),
    ): Response =
        Response.newBuilder()
            .setError(
                io.apkrun.guest.protocol.v1.GuestError.newBuilder()
                    .setCode(code)
                    .setMessage(message)
                    .putAllDetail(detail)
                    .build()
            )
            .build()
}
