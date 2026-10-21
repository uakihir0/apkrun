package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Shutdown
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class SystemOperationsTest {
    @Test
    fun shutdownRunsOnlyAfterTheResponseCanBeWritten() {
        var shutDownWith: String? = null
        val operations = SystemOperations(powerOff = { shutDownWith = it })

        operations.shutdown(27, Shutdown.newBuilder().setReason("host shutdown").build())

        assertNull(shutDownWith)
        operations.responseSent(27)
        assertEquals("host shutdown", shutDownWith)
    }

    @Test
    fun shutdownRejectsUnboundedOrControlCharacterReasonsBeforeScheduling() {
        var shutDownWith: String? = null
        val operations = SystemOperations(powerOff = { shutDownWith = it })
        val failure =
            assertThrows(GuestFailure::class.java) {
                operations.shutdown(29, Shutdown.newBuilder().setReason("bad\nreason").build())
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, failure.code)
        operations.responseSent(29)
        assertNull(shutDownWith)
    }

    @Test
    fun shutdownIsCancelledWhenItsResponseCannotBeWritten() {
        var shutDownWith: String? = null
        val operations = SystemOperations(powerOff = { shutDownWith = it })

        operations.shutdown(31, Shutdown.newBuilder().setReason("host shutdown").build())
        operations.responseFailed(31)
        operations.responseSent(31)

        assertNull(shutDownWith)
    }
}
