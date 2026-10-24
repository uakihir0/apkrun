package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Shutdown
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.SystemServices
import java.util.concurrent.ConcurrentHashMap

/**
 * System operations that need privileged framework calls (system.v1, guest-protocol.md §7.1).
 * Shutdown is scheduled after this operation returns, giving the connection time to send Empty.
 */
class SystemOperations(
    private val powerOff: (String) -> Unit = { reason ->
        SystemServices.power.call("shutdown", false, reason, false)
    }
) {
    private val pendingShutdowns = ConcurrentHashMap<Long, () -> Unit>()

    fun shutdown(requestId: Long, request: Shutdown) {
        val reason = request.reason
        if (reason.length > MAXIMUM_REASON_CHARACTERS || reason.any(Char::isISOControl)) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the shutdown reason is not valid",
            )
        }
        pendingShutdowns[requestId] = { powerOff(reason) }
    }

    /** Starts power-off after the Empty response has been flushed to the host. */
    fun responseSent(requestId: Long) {
        val shutdown = pendingShutdowns.remove(requestId) ?: return
        try {
            shutdown()
        } catch (error: Exception) {
            AgentLog.error("the guest could not shut down after the host request", error)
        } catch (error: LinkageError) {
            AgentLog.error("the guest could not shut down after the host request", error)
        }
    }

    /** Drops a queued shutdown if the connection could not confirm it to the host. */
    fun responseFailed(requestId: Long) {
        pendingShutdowns.remove(requestId)
    }

    private companion object {
        const val MAXIMUM_REASON_CHARACTERS = 256
    }
}
