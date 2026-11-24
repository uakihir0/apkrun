package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
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

    private fun operations(appProcessMonitorAvailable: Boolean): Set<GuestCapability> =
        DeviceOperations.supportedCapabilities(
            hasMethod = { _: SystemServiceWrapper, _: String -> true },
            appProcessMonitoringAvailable = { appProcessMonitorAvailable },
        )
}
