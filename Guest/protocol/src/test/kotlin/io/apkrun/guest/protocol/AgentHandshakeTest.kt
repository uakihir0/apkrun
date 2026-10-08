package io.apkrun.guest.protocol

import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.Accepted
import io.apkrun.guest.protocol.v1.HelloAck
import io.apkrun.guest.protocol.v1.ProtocolVersion as WireProtocolVersion
import io.apkrun.guest.protocol.v1.RejectReason
import io.apkrun.guest.protocol.v1.Rejected
import kotlin.reflect.KClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

private val sessionToken = ByteArray(16) { (it + 1).toByte() }

private fun acceptedAck(
    major: Int = 1,
    minor: Int = 0,
    capabilities: List<String> = listOf("core.v1", "display.v1"),
): HelloAck =
    HelloAck.newBuilder()
        .setAccepted(Accepted.getDefaultInstance())
        .setHostProtocolVersion(WireProtocolVersion.newBuilder().setMajor(major).setMinor(minor))
        .setSessionToken(ByteString.copyFrom(sessionToken))
        .addAllEnabledCapabilities(capabilities)
        .build()

private fun rejectedAck(reason: RejectReason, hostMajor: Int = 1): HelloAck =
    HelloAck.newBuilder()
        .setRejected(Rejected.newBuilder().setReason(reason).setDetail("test"))
        .setHostProtocolVersion(WireProtocolVersion.newBuilder().setMajor(hostMajor).setMinor(0))
        .build()

/** Runs [block], which must throw a [GuestProtocolFailure] of [expected], and checks its fields. */
private fun assertFailsWith(
    expected: KClass<out GuestProtocolFailure>,
    block: () -> Unit,
): GuestProtocolFailure {
    val failure =
        try {
            block()
            throw AssertionError("expected $expected, but the handshake was accepted")
        } catch (failure: GuestProtocolFailure) {
            failure
        }
    assertEquals("failure of $failure", expected, failure::class)
    return failure
}

class AgentHandshakeTest {
    @Test
    fun `the same major version is accepted and its capabilities are narrowed`() {
        val accepted =
            AgentHandshake.evaluate(
                acceptedAck(capabilities = listOf("display.v1", "future.thing.v9", "core.v1"))
            )
        assertEquals(ProtocolVersion(1, 0), accepted.hostVersion)
        assertEquals(listOf("core.v1", "display.v1"), accepted.enabledCapabilities)
        assertTrue(accepted.sessionToken.contentEquals(sessionToken))
    }

    @Test
    fun `a higher minor version is accepted`() {
        val accepted = AgentHandshake.evaluate(acceptedAck(minor = 5))
        assertEquals(ProtocolVersion(1, 5), accepted.hostVersion)
    }

    @Test
    fun `a host with a different major version is an incompatible version`() {
        val failure =
            assertFailsWith(GuestProtocolFailure.IncompatibleVersion::class) {
                AgentHandshake.evaluate(acceptedAck(major = 2))
            }
                as GuestProtocolFailure.IncompatibleVersion
        assertEquals(ProtocolVersion(2, 0), failure.host)
        assertEquals(ProtocolVersion.HOST, failure.guest)
    }

    @Test
    fun `a host with an older major version is an incompatible version`() {
        assertFailsWith(GuestProtocolFailure.IncompatibleVersion::class) {
            AgentHandshake.evaluate(acceptedAck(major = 0, minor = 9))
        }
    }

    @Test
    fun `a capability that the host enables but the agent does not implement is left out`() {
        // The handshake still succeeds. The host learns from UNSUPPORTED on the first request
        // that uses the capability (guest-protocol.md §5.2, §5.3; IR-268).
        val accepted =
            AgentHandshake.evaluate(
                acceptedAck(capabilities = listOf("display.v1", "core.v1")),
                implemented = setOf(GuestCapability.CORE),
            )
        assertEquals(listOf("core.v1"), accepted.enabledCapabilities)
    }

    @Test
    fun `a host major version of 2^31 is newer than supported, not older`() {
        // The wire value 0x80000000 arrives as a negative Int, and it must not be read as older.
        val failure =
            assertFailsWith(GuestProtocolFailure.IncompatibleVersion::class) {
                AgentHandshake.evaluate(acceptedAck(major = Int.MIN_VALUE))
            }
                as GuestProtocolFailure.IncompatibleVersion
        assertEquals(2_147_483_648L, failure.host.major)
        assertEquals(
            ProtocolCompatibility.ABOVE_SUPPORTED,
            ProtocolVersion.compatibility(failure.host),
        )
    }

    @Test
    fun `a rejection for an incompatible version is reported as an incompatible version`() {
        assertFailsWith(GuestProtocolFailure.IncompatibleVersion::class) {
            AgentHandshake.evaluate(
                rejectedAck(RejectReason.REJECT_REASON_INCOMPATIBLE_VERSION, hostMajor = 2)
            )
        }
    }

    @Test
    fun `a rejection for a wrong channel is a handshake failure`() {
        val failure =
            assertFailsWith(GuestProtocolFailure.HandshakeFailed::class) {
                AgentHandshake.evaluate(rejectedAck(RejectReason.REJECT_REASON_WRONG_CHANNEL))
            }
                as GuestProtocolFailure.HandshakeFailed
        assertEquals(HandshakeFailureReason.WRONG_CHANNEL, failure.reason)
    }

    @Test
    fun `a rejection for a bad token is a handshake failure`() {
        val failure =
            assertFailsWith(GuestProtocolFailure.HandshakeFailed::class) {
                AgentHandshake.evaluate(rejectedAck(RejectReason.REJECT_REASON_BAD_TOKEN))
            }
                as GuestProtocolFailure.HandshakeFailed
        assertEquals(HandshakeFailureReason.BAD_TOKEN, failure.reason)
    }

    @Test
    fun `a rejection for a duplicate session is a handshake failure`() {
        val failure =
            assertFailsWith(GuestProtocolFailure.HandshakeFailed::class) {
                AgentHandshake.evaluate(rejectedAck(RejectReason.REJECT_REASON_DUPLICATE_SESSION))
            }
                as GuestProtocolFailure.HandshakeFailed
        assertEquals(HandshakeFailureReason.DUPLICATE_SESSION, failure.reason)
    }

    @Test
    fun `an accepted handshake without a host version is malformed`() {
        val ack = HelloAck.newBuilder().setAccepted(Accepted.getDefaultInstance()).build()
        assertFalse(ack.hasHostProtocolVersion())
        assertFailsWith(GuestProtocolFailure.MalformedFrame::class) { AgentHandshake.evaluate(ack) }
    }

    @Test
    fun `a HelloAck with neither accepted nor rejected is malformed`() {
        // The version and the token are present, so only the missing outcome can cause the failure.
        val ack =
            HelloAck.newBuilder()
                .setHostProtocolVersion(WireProtocolVersion.newBuilder().setMajor(1).setMinor(0))
                .setSessionToken(ByteString.copyFrom(sessionToken))
                .addAllEnabledCapabilities(listOf("core.v1"))
                .build()
        assertEquals(HelloAck.OutcomeCase.OUTCOME_NOT_SET, ack.outcomeCase)
        assertFailsWith(GuestProtocolFailure.MalformedFrame::class) { AgentHandshake.evaluate(ack) }
    }
}
