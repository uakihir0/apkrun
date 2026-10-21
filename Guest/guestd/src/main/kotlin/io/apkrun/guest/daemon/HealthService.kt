package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.protocol.v1.GuestError
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Health
import io.apkrun.guest.protocol.v1.HealthWarning
import io.apkrun.guest.protocol.v1.HealthWarningKind
import io.apkrun.guest.protocol.v1.InputCounters
import io.apkrun.guest.protocol.v1.MemoryInfo
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Memory values already converted to the Guest Protocol's KiB units. */
data class GuestMemorySnapshot(
    val totalKb: Long,
    val availableKb: Long,
    val lowMemory: Boolean,
)

/**
 * Health snapshot and warnings (health.v1, guest-protocol.md §7.4 and §8.1). Android reads and
 * callback registration are injected so T1 tests can exercise this service without a VM.
 */
class HealthService(
    private val events: EventBus,
    private val uptimeMillis: () -> Long,
    private val mode: () -> AgentMode,
    private val displaysCount: () -> Int,
    private val imeSelected: () -> Boolean,
    private val notificationListenerEnabled: () -> Boolean,
    private val adbEnabled: () -> Boolean,
    private val memory: () -> GuestMemorySnapshot,
    private val inputCounters: () -> InputCounters,
    private val openSessions: () -> Int,
    private val registerLowMemoryCallback: ((() -> Unit) -> Unit) = {},
    private val postCallback: ((() -> Unit) -> Unit) = { work -> work() },
    private val missingMethods: () -> List<String> = { emptyList() },
) {
    private val startedAtUptimeMillis = uptimeMillis().coerceAtLeast(0L)
    private val lastError = AtomicReference<GuestError?>()
    private val lowMemoryWarningSent = AtomicBoolean(false)

    /** Starts the Android low-memory callback, when this image has one available. */
    fun start() {
        registerLowMemoryCallback { postCallback(::onLowMemory) }
    }

    /** Reads the current status from Android-backed suppliers. */
    fun getHealth(): Health {
        val currentMemory = memory()
        if (currentMemory.lowMemory) {
            onLowMemory()
        } else {
            lowMemoryWarningSent.set(false)
        }
        val builder =
            Health.newBuilder()
                .setAgentUptimeMs((uptimeMillis() - startedAtUptimeMillis).coerceAtLeast(0L))
                .setMode(mode())
                .setDisplaysCount(displaysCount().coerceAtLeast(0))
                .setImeSelected(imeSelected())
                .setNotificationListenerEnabled(notificationListenerEnabled())
                .setAdbEnabled(adbEnabled())
                .setMemory(
                    MemoryInfo.newBuilder()
                        .setTotalKb(currentMemory.totalKb.coerceAtLeast(0L))
                        .setAvailableKb(currentMemory.availableKb.coerceAtLeast(0L))
                        .setLowMemory(currentMemory.lowMemory)
                )
                .setInput(inputCounters())
                .setOpenSessions(openSessions().coerceAtLeast(0))
        val missing = missingMethods().distinct().sorted()
        val recordedError = lastError.get()
        if (recordedError != null || missing.isNotEmpty()) {
            val error =
                recordedError?.toBuilder()
                    ?: GuestError.newBuilder()
                        .setCode(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED)
                        .setMessage("some system service methods are unavailable")
            if (missing.isNotEmpty()) {
                error.putDetail("missing_methods", missing.joinToString(","))
            }
            builder.setLastError(error)
        }
        return builder.build()
    }

    /** Remembers the most recent operation error without logging its details. */
    fun recordFailure(error: GuestError) {
        lastError.set(error)
    }

    /**
     * Reports Android's low-memory callbacks and `MemoryInfo.lowMemory` at most once per episode.
     */
    fun onLowMemory() {
        if (!lowMemoryWarningSent.compareAndSet(false, true)) return
        events.publish(GuestCapability.HEALTH) {
            it.setHealthWarning(
                HealthWarning.newBuilder()
                    .setKind(HealthWarningKind.HEALTH_WARNING_KIND_LOW_MEMORY)
                    .setDetail("Android reported low memory")
            )
        }
    }
}
