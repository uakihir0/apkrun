package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.Empty
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Pong
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import io.apkrun.guest.runtime.ServiceMethodMissing
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Routes each `Request.op` to its operation (guest-protocol.md §6, guest-components.md §6.1). It
 * enforces the capabilities that the host enabled, the timeouts, and the serial order per display.
 * Operations on the same display run one at a time, and operations on different displays run in
 * parallel (guest-components.md §6.3).
 */
class Dispatcher(
    private val operations: AgentOperations,
    private val uptimeMillis: () -> Long,
    private val defaultTimeoutMillis: Long = DEFAULT_TIMEOUT_MILLIS,
) {
    private val displayExecutors = ConcurrentHashMap<Int, CoroutineDispatcher>()
    private val active = ConcurrentHashMap<Long, Deferred<Response?>>()
    private val cancelled = ConcurrentHashMap.newKeySet<Long>()

    /**
     * Answers one request with id [id]. The caller sends the returned response with `reply_to` set
     * to [id]. A request for an operation this build does not have, or for a capability the host
     * did not enable, is answered with UNSUPPORTED (guest-protocol.md §5.2, §5.3).
     */
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
            // The operation runs in its own child coroutine. Cancelling it must not cancel the
            // caller, which still
            // has to send the response.
            return coroutineScope {
                val work = async { withTimeoutOrNull(timeout) { run(request) } }
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
        } catch (error: GuestFailure) {
            return Response.newBuilder().setError(error.toGuestError()).build()
        } catch (error: ServiceMethodMissing) {
            return failure(
                GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                "the system service ${error.service} has no usable ${error.method} on this image",
                mapOf("method" to error.method),
            )
        } catch (error: SecurityException) {
            return failure(
                GuestErrorCode.GUEST_ERROR_CODE_PERMISSION_DENIED,
                "Android refused the operation",
            )
        } catch (error: RuntimeException) {
            return failure(
                GuestErrorCode.GUEST_ERROR_CODE_INTERNAL,
                "the operation failed",
                mapOf("exception" to error.javaClass.name),
            )
        } finally {
            active.remove(id)
            cancelled.remove(id)
        }
    }

    /**
     * Cancels the request [targetId] if it is still running. The response still arrives
     * (guest-protocol.md §4.1).
     */
    fun cancel(targetId: Long) {
        val job = active[targetId] ?: return
        cancelled.add(targetId)
        job.cancel()
    }

    private suspend fun run(request: Request): Response =
        when (request.opCase) {
            Request.OpCase.PING ->
                Response.newBuilder()
                    .setPing(
                        Pong.newBuilder()
                            .setNonce(request.ping.nonce)
                            .setGuestUptimeMs(uptimeMillis())
                    )
                    .build()
            Request.OpCase.GET_SNAPSHOT ->
                Response.newBuilder().setGetSnapshot(operations.snapshot()).build()
            Request.OpCase.SET_DISPLAY_POLICY -> {
                val policy = request.setDisplayPolicy
                withContext(executorFor(policy.displayId)) { operations.setDisplayPolicy(policy) }
                Response.newBuilder().setSetDisplayPolicy(Empty.getDefaultInstance()).build()
            }
            Request.OpCase.LAUNCH_APPLICATION -> {
                val launch = request.launchApplication
                val result =
                    withContext(executorFor(launch.displayId)) {
                        operations.launchApplication(launch)
                    }
                Response.newBuilder().setLaunchApplication(result).build()
            }
            Request.OpCase.FOCUS_DISPLAY -> {
                val displayId = request.focusDisplay.displayId
                withContext(executorFor(displayId)) { operations.focusDisplay(displayId) }
                Response.newBuilder().setFocusDisplay(Empty.getDefaultInstance()).build()
            }
            else ->
                failure(
                    GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                    "this agent build has no such operation",
                )
        }

    /**
     * The one-at-a-time executor of [displayId]. It is created on first use and kept for the
     * agent's life.
     */
    private fun executorFor(displayId: Int): CoroutineDispatcher =
        displayExecutors.getOrPut(displayId) { Dispatchers.Default.limitedParallelism(1) }

    companion object {
        /**
         * The default operation timeout of the agent, used when the request carries none
         * (guest-protocol.md §6).
         */
        const val DEFAULT_TIMEOUT_MILLIS = 5_000L

        /**
         * The capability of each operation that this build implements (guest-protocol.md §5.3). An
         * operation that this build does not implement has no capability here, so it is answered
         * with UNSUPPORTED.
         */
        fun requiredCapability(operation: Request.OpCase): GuestCapability? =
            when (operation) {
                Request.OpCase.PING,
                Request.OpCase.GET_SNAPSHOT -> GuestCapability.CORE
                Request.OpCase.SET_DISPLAY_POLICY -> GuestCapability.DISPLAY
                Request.OpCase.LAUNCH_APPLICATION -> GuestCapability.LAUNCH
                Request.OpCase.FOCUS_DISPLAY -> GuestCapability.INPUT
                else -> null
            }

        /** A response with only an error, and no result. */
        fun failure(
            code: GuestErrorCode,
            message: String,
            detail: Map<String, String> = emptyMap(),
        ): Response =
            Response.newBuilder()
                .setError(GuestFailure(code, message, detail).toGuestError())
                .build()
    }
}
