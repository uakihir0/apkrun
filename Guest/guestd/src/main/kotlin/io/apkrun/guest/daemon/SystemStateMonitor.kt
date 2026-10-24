package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.SystemState

/** Publishes only system-state transitions, leaving initial state to GetSnapshot (core.v1). */
class SystemStateMonitor(
    private val events: EventBus,
    private val readState: () -> SystemState,
    private val registerChangeCallback: (() -> Unit) -> Unit,
) {
    @Volatile private var previous: SystemState? = null

    fun start() {
        previous = readState()
        registerChangeCallback(::refresh)
    }

    fun refresh() {
        val current = readState()
        val before = previous
        if (before != null && before != current) {
            events.publish(GuestCapability.CORE) { it.setSystemStateChanged(current) }
        }
        previous = current
    }
}
