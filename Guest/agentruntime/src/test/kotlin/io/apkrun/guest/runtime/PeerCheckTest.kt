package io.apkrun.guest.runtime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The stock and custom image `SO_PEERCRED` policies in guest-components.md §10.1. */
class PeerCheckTest {
    @Test
    fun developmentShellModeAcceptsOnlyStockImagePeers() {
        for (developerModeProperty in listOf(null, "", "0", "1")) {
            assertTrue(
                PeerCheck.isAllowed(
                    PeerCheck.SHELL_UID,
                    PeerPolicy.STOCK_DEVELOPMENT,
                    developerModeProperty,
                )
            )
            assertTrue(
                PeerCheck.isAllowed(
                    PeerCheck.ROOT_UID,
                    PeerPolicy.STOCK_DEVELOPMENT,
                    developerModeProperty,
                )
            )
            assertFalse(
                PeerCheck.isAllowed(
                    PeerCheck.SYSTEM_UID,
                    PeerPolicy.STOCK_DEVELOPMENT,
                    developerModeProperty,
                )
            )
        }
    }

    @Test
    fun privilegedAppModeFailsClosedUntilDeveloperModeIsExplicitlyEnabled() {
        for (developerModeProperty in listOf(null, "", "0", "true", "unexpected")) {
            assertTrue(
                PeerCheck.isAllowed(
                    PeerCheck.SYSTEM_UID,
                    PeerPolicy.CUSTOM_PRODUCT,
                    developerModeProperty,
                )
            )
            assertTrue(
                PeerCheck.isAllowed(
                    PeerCheck.ROOT_UID,
                    PeerPolicy.CUSTOM_PRODUCT,
                    developerModeProperty,
                )
            )
            assertFalse(
                PeerCheck.isAllowed(
                    PeerCheck.SHELL_UID,
                    PeerPolicy.CUSTOM_PRODUCT,
                    developerModeProperty,
                )
            )
        }
        assertTrue(
            PeerCheck.isAllowed(
                PeerCheck.SHELL_UID,
                PeerPolicy.CUSTOM_PRODUCT,
                "1",
            )
        )
    }

    @Test
    fun unspecifiedModeFailsClosed() {
        for (uid in listOf(PeerCheck.SHELL_UID, PeerCheck.SYSTEM_UID, PeerCheck.ROOT_UID)) {
            assertFalse(PeerCheck.isAllowed(uid, PeerPolicy.REJECT_ALL, "1"))
        }
    }

    @Test
    fun stockImageKeepsAllowingShellAndRootInBothDeveloperModes() {
        for (developerMode in listOf(false, true)) {
            assertTrue(PeerCheck.isAllowed(PeerCheck.SHELL_UID, customImage = false, developerMode))
            assertTrue(PeerCheck.isAllowed(PeerCheck.ROOT_UID, customImage = false, developerMode))
            assertFalse(
                PeerCheck.isAllowed(PeerCheck.SYSTEM_UID, customImage = false, developerMode)
            )
        }
    }

    @Test
    fun customImageAllowsSystemAndRootWithDeveloperModeOff() {
        assertTrue(
            PeerCheck.isAllowed(PeerCheck.SYSTEM_UID, customImage = true, developerMode = false)
        )
        assertTrue(
            PeerCheck.isAllowed(PeerCheck.ROOT_UID, customImage = true, developerMode = false)
        )
        assertFalse(
            PeerCheck.isAllowed(PeerCheck.SHELL_UID, customImage = true, developerMode = false)
        )
    }

    @Test
    fun customImageAllowsShellWithDeveloperModeOn() {
        assertTrue(
            PeerCheck.isAllowed(PeerCheck.SYSTEM_UID, customImage = true, developerMode = true)
        )
        assertTrue(
            PeerCheck.isAllowed(PeerCheck.ROOT_UID, customImage = true, developerMode = true)
        )
        assertTrue(
            PeerCheck.isAllowed(PeerCheck.SHELL_UID, customImage = true, developerMode = true)
        )
    }

    @Test
    fun unrecognizedUidsAreRejectedForEveryImageMode() {
        for (customImage in listOf(false, true)) {
            for (developerMode in listOf(false, true)) {
                assertFalse(PeerCheck.isAllowed(1001, customImage, developerMode))
            }
        }
    }
}
