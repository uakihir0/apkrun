package io.apkrun.guest.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolVersionTest {
    @Test
    fun `a major version of 2^31 is read as unsigned and is newer than supported`() {
        val version = ProtocolVersion.fromWire(Int.MIN_VALUE, 0)
        assertEquals(2_147_483_648L, version.major)
        assertEquals(ProtocolCompatibility.ABOVE_SUPPORTED, ProtocolVersion.compatibility(version))
    }

    @Test
    fun `the largest uint32 major is newer than supported, not below it`() {
        val version = ProtocolVersion.fromWire(-1, 0)
        assertEquals(4_294_967_295L, version.major)
        assertEquals(ProtocolCompatibility.ABOVE_SUPPORTED, ProtocolVersion.compatibility(version))
    }

    @Test
    fun `a minor version of 2^31 orders after a small one`() {
        val small = ProtocolVersion.fromWire(1, 1)
        val large = ProtocolVersion.fromWire(1, Int.MIN_VALUE)
        assertTrue(small < large)
        assertEquals("1.2147483648", large.toString())
    }

    @Test
    fun `major 1 is compatible whatever its minor is`() {
        assertEquals(
            ProtocolCompatibility.COMPATIBLE,
            ProtocolVersion.compatibility(ProtocolVersion.fromWire(1, -1)),
        )
    }

    @Test
    fun `a major below the supported range is older`() {
        assertEquals(
            ProtocolCompatibility.BELOW_SUPPORTED,
            ProtocolVersion.compatibility(ProtocolVersion.fromWire(0, 9)),
        )
    }
}
