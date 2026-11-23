package io.apkrun.store

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.Empty
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Routes each store `Request.op` to its operation (guest-protocol.md §6, §11). It enforces the
 * capabilities that the host enabled and the per-request timeout. A request for an operation this
 * agent does not build, or for a capability the host did not enable, is answered UNSUPPORTED
 * (guest-protocol.md §5.3).
 */
class StoreDispatcher(
    private val operations: StoreOperations,
    private val uptimeMillis: () -> Long,
    private val defaultTimeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
) {
    private val active = ConcurrentHashMap<Long, Deferred<Response?>>()
    private val cancelled = ConcurrentHashMap.newKeySet<Long>()

    suspend fun dispatch(id: Long, request: Request, enabled: Set<GuestCapability>): Response {
        val capability = requiredCapability(request.opCase)
        if (capability == null) {
            return failure(
                GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                "this agent build has no such operation",
            )
        }
        if (capability !in enabled) {
            return failure(
                GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                "the capability ${capability.wireName} is not enabled for this connection",
            )
        }
        val timeout =
            if (request.timeoutMs > 0) request.timeoutMs.toLong() else defaultTimeoutMillis
        try {
            return coroutineScope {
                val work = async { withTimeoutOrNull(timeout) { run(request, enabled) } }
                active[id] = work
                work.await()
                    ?: failure(
                        GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT,
                        "the operation did not finish within $timeout ms",
                    )
            }
        } catch (error: CancellationException) {
            if (cancelled.remove(id)) {
                return failure(
                    GuestErrorCode.GUEST_ERROR_CODE_CANCELLED,
                    "the request was cancelled by the host",
                )
            }
            throw error
        } catch (failure: GuestFailure) {
            return failure.toGuestError().let {
                Response.newBuilder().setError(it).build()
            }
        } catch (error: Exception) {
            // A framework exception must not kill the agent: answer with an error instead.
            io.apkrun.guest.runtime.AgentLog.error(
                "store operation ${request.opCase} failed",
                error,
            )
            return failure(
                GuestErrorCode.GUEST_ERROR_CODE_INTERNAL,
                "the operation failed",
            )
        } finally {
            active.remove(id)
        }
    }

    /** Best effort: the response still arrives, as CANCELLED or the result (§6). */
    fun cancel(targetId: Long) {
        cancelled += targetId
        active[targetId]?.cancel()
    }

    private suspend fun run(request: Request, enabled: Set<GuestCapability>): Response {
        val response = Response.newBuilder()
        when (request.opCase) {
            Request.OpCase.PING -> response.ping = operations.ping()
            Request.OpCase.BEGIN_INSTALL -> {
                // A flag that needs a capability the host did not enable is INVALID_ARGUMENT
                // (guest-protocol.md §11.3).
                val install = request.beginInstall
                if (install.requestUpdateOwnership && GuestCapability.STORE_OWNERSHIP !in enabled) {
                    throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "request_update_ownership needs store.ownership.v1",
                    )
                }
                if (install.enableRollback && GuestCapability.STORE_ROLLBACK !in enabled) {
                    throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "enable_rollback needs store.rollback.v1",
                    )
                }
                response.beginInstall = operations.beginInstall(install)
            }
            Request.OpCase.COMMIT_INSTALL -> {
                operations.commitInstall(request.commitInstall.installId)
                response.commitInstall = Empty.getDefaultInstance()
            }
            Request.OpCase.ABANDON_INSTALL -> {
                operations.abandonInstall(request.abandonInstall.installId)
                response.abandonInstall = Empty.getDefaultInstance()
            }
            Request.OpCase.UNINSTALL -> response.uninstall = operations.uninstall(request.uninstall)
            Request.OpCase.GET_PACKAGE_METADATA ->
                operations.getPackageMetadata(request.getPackageMetadata.`package`)?.let {
                    response.getPackageMetadata = it
                }
                    ?: throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                        "the package is not installed",
                    )
            Request.OpCase.LIST_MANAGED_PACKAGES ->
                response.listManagedPackages =
                    operations.listManagedPackages(request.listManagedPackages)
            Request.OpCase.RELINQUISH_UPDATE_OWNERSHIP -> {
                operations.relinquishUpdateOwnership(request.relinquishUpdateOwnership.`package`)
                response.relinquishUpdateOwnership = Empty.getDefaultInstance()
            }
            Request.OpCase.ROLLBACK_PACKAGE ->
                response.rollbackPackage = operations.rollbackPackage(request.rollbackPackage)
            Request.OpCase.CHECK_INSTALL_CONSTRAINTS ->
                response.checkInstallConstraints =
                    operations.checkInstallConstraints(request.checkInstallConstraints)
            Request.OpCase.RENDER_ICON ->
                response.renderIcon = operations.renderIcon(request.renderIcon)
            else ->
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                    "this agent build has no such operation",
                )
        }
        return response.build()
    }

    private fun failure(code: GuestErrorCode, message: String): Response =
        Response.newBuilder()
            .setError(
                io.apkrun.guest.protocol.v1.GuestError.newBuilder()
                    .setCode(code)
                    .setMessage(message)
            )
            .build()

    companion object {
        const val DEFAULT_TIMEOUT_MILLIS = 30_000L

        /** The capability each store operation needs (guest-protocol.md §11.1). */
        fun requiredCapability(operation: Request.OpCase): GuestCapability? =
            when (operation) {
                Request.OpCase.PING -> GuestCapability.CORE
                Request.OpCase.BEGIN_INSTALL,
                Request.OpCase.COMMIT_INSTALL,
                Request.OpCase.ABANDON_INSTALL -> GuestCapability.STORE_INSTALL
                Request.OpCase.UNINSTALL,
                Request.OpCase.GET_PACKAGE_METADATA,
                Request.OpCase.LIST_MANAGED_PACKAGES -> GuestCapability.STORE_METADATA
                Request.OpCase.INSPECT_ARCHIVE -> GuestCapability.STORE_METADATA
                Request.OpCase.RENDER_ICON -> GuestCapability.STORE_ICON
                Request.OpCase.ROLLBACK_PACKAGE -> GuestCapability.STORE_ROLLBACK
                Request.OpCase.RELINQUISH_UPDATE_OWNERSHIP -> GuestCapability.STORE_OWNERSHIP
                Request.OpCase.CHECK_INSTALL_CONSTRAINTS -> GuestCapability.STORE_CONSTRAINTS
                else -> null
            }
    }
}
