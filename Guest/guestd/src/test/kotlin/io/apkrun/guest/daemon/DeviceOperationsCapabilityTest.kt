package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.protocol.v1.InputCounters
import io.apkrun.guest.runtime.SystemServiceWrapper
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DeviceOperationsCapabilityTest {
    @Test
    fun healthRequiresTheAppProcessMonitorToRegister() {
        assertFalse(GuestCapability.HEALTH in operations(appProcessMonitorAvailable = false))
        assertTrue(GuestCapability.HEALTH in operations(appProcessMonitorAvailable = true))
    }

    private fun operations(appProcessMonitorAvailable: Boolean): Set<GuestCapability> {
        val events = EventBus()
        val displays = DisplayService(events, callbacks = {})
        val tasks = TaskService(events, callbacks = {})
        val launch =
            LaunchService(tasks, displays) { error("launch is not used by capability checks") }
        val packages =
            PackageService(
                object : PackageCatalog {
                    override fun find(packageName: String): GuestPackageFacts? = null

                    override fun listInstalled(): List<GuestPackageSummaryFacts> = emptyList()
                }
            )
        val health =
            HealthService(
                events = events,
                uptimeMillis = { 0L },
                mode = { AgentMode.AGENT_MODE_DEVELOPMENT_SHELL },
                displaysCount = { 0 },
                imeSelected = { false },
                notificationListenerEnabled = { false },
                adbEnabled = { false },
                memory = { GuestMemorySnapshot(0, 0, false) },
                inputCounters = { InputCounters.getDefaultInstance() },
                openSessions = { 0 },
            )
        return DeviceOperations(
                displays = displays,
                tasks = tasks,
                launch = launch,
                packages = packages,
                health = health,
                system = SystemOperations(powerOff = {}),
                appProcessMonitoringAvailable = { appProcessMonitorAvailable },
                hasMethod = { _: SystemServiceWrapper, _: String -> true },
            )
            .supportedCapabilities()
    }
}
