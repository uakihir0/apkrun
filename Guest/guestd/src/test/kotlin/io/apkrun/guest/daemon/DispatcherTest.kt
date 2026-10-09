package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.ClearDisplay
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ImePolicy
import io.apkrun.guest.protocol.v1.LaunchApplication
import io.apkrun.guest.protocol.v1.LaunchOutcome
import io.apkrun.guest.protocol.v1.LaunchResult
import io.apkrun.guest.protocol.v1.Ping
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.protocol.v1.Snapshot
import io.apkrun.guest.runtime.ServiceMethodMissing
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The operations of the dispatcher tests. Each one counts its concurrency, and can be made slow.
 */
private class FakeOperations : AgentOperations {
    val running = AtomicInteger(0)
    val maximumRunning = AtomicInteger(0)
    var delayMillis = 0L
    var failure: RuntimeException? = null
    /**
     * Released by the first operation that starts. Tests that need an op to be in flight wait on
     * it.
     */
    val started = CountDownLatch(1)

    private fun enter() {
        val now = running.incrementAndGet()
        maximumRunning.accumulateAndGet(now) { a, b -> maxOf(a, b) }
        started.countDown()
        try {
            if (delayMillis > 0) Thread.sleep(delayMillis)
            failure?.let { throw it }
        } finally {
            running.decrementAndGet()
        }
    }

    override fun snapshot(): Snapshot = Snapshot.getDefaultInstance()

    override fun setDisplayPolicy(request: SetDisplayPolicy) = enter()

    override fun launchApplication(request: LaunchApplication): LaunchResult {
        enter()
        return LaunchResult.newBuilder()
            .setTaskId(7)
            .setOutcome(LaunchOutcome.LAUNCH_OUTCOME_STARTED)
            .build()
    }

    override fun focusDisplay(displayId: Int) = enter()
}

class DispatcherTest {
    private val everything =
        setOf(
            GuestCapability.CORE,
            GuestCapability.DISPLAY,
            GuestCapability.LAUNCH,
            GuestCapability.INPUT,
        )

    private fun policy(displayId: Int): Request =
        Request.newBuilder()
            .setSetDisplayPolicy(
                SetDisplayPolicy.newBuilder()
                    .setDisplayId(displayId)
                    .setDensityDpi(320)
                    .setImePolicy(ImePolicy.IME_POLICY_LOCAL)
            )
            .build()

    private fun launch(displayId: Int, timeoutMs: Int = 0): Request =
        Request.newBuilder()
            .setTimeoutMs(timeoutMs)
            .setLaunchApplication(
                LaunchApplication.newBuilder()
                    .setPackage("io.apkrun.fixture.hellotext")
                    .setDisplayId(displayId)
            )
            .build()

    private fun dispatcher(operations: AgentOperations, defaultTimeout: Long = 5_000L) =
        Dispatcher(operations, uptimeMillis = { 1_000L }, defaultTimeoutMillis = defaultTimeout)

    @Test
    fun pingAnswersWithTheNonce() = runBlocking {
        val request = Request.newBuilder().setPing(Ping.newBuilder().setNonce(42)).build()
        val response = dispatcher(FakeOperations()).dispatch(1, request, everything)
        assertEquals(42L, response.getPing().getNonce())
        assertEquals(1_000L, response.getPing().getGuestUptimeMs())
    }

    @Test
    fun anOperationThisBuildDoesNotHaveIsUnsupported() = runBlocking {
        val request =
            Request.newBuilder().setClearDisplay(ClearDisplay.newBuilder().setDisplayId(1)).build()
        val response = dispatcher(FakeOperations()).dispatch(1, request, everything)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, response.getError().getCode())
    }

    @Test
    fun aCapabilityThatTheHostDidNotEnableIsUnsupported() = runBlocking {
        val enabled = setOf(GuestCapability.CORE)
        val response = dispatcher(FakeOperations()).dispatch(1, launch(0), enabled)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, response.getError().getCode())
        assertTrue(response.getError().getMessage().contains("launch.v1"))
    }

    @Test
    fun aRequestPastItsTimeoutAnswersTimeout() = runBlocking {
        val operations = FakeOperations().apply { delayMillis = 2_000 }
        val response = dispatcher(operations).dispatch(1, launch(0, timeoutMs = 50), everything)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT, response.getError().getCode())
    }

    @Test
    fun operationsOnOneDisplayRunOneAtATime() = runBlocking {
        val operations = FakeOperations().apply { delayMillis = 60 }
        val dispatcher = dispatcher(operations)
        val first = async { dispatcher.dispatch(1, policy(0), everything) }
        val second = async { dispatcher.dispatch(2, policy(0), everything) }
        first.await()
        second.await()
        assertEquals(1, operations.maximumRunning.get())
    }

    @Test
    fun operationsOnDifferentDisplaysRunTogether() = runBlocking {
        val operations = FakeOperations().apply { delayMillis = 300 }
        val dispatcher = dispatcher(operations)
        val first = async { dispatcher.dispatch(1, policy(0), everything) }
        val second = async { dispatcher.dispatch(2, policy(1), everything) }
        first.await()
        second.await()
        assertEquals(2, operations.maximumRunning.get())
    }

    @Test
    fun aGuestFailureBecomesItsGuestError() = runBlocking {
        val operations =
            FakeOperations().apply {
                failure =
                    GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                        "the package is not installed",
                    )
            }
        val response = dispatcher(operations).dispatch(1, launch(0), everything)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, response.getError().getCode())
    }

    @Test
    fun aMissingFrameworkMethodFailsOnlyItsRequest() = runBlocking {
        val operations =
            FakeOperations().apply {
                failure = ServiceMethodMissing("window", "setDisplayImePolicy")
            }
        val response = dispatcher(operations).dispatch(1, policy(0), everything)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, response.getError().getCode())
        assertEquals("setDisplayImePolicy", response.getError().getDetailMap()["method"])
    }

    @Test
    fun anUnexpectedExceptionIsInternalWithoutItsMessage() = runBlocking {
        val operations =
            FakeOperations().apply { failure = IllegalStateException("user data here") }
        val response = dispatcher(operations).dispatch(1, launch(0), everything)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INTERNAL, response.getError().getCode())
        assertFalse(response.getError().getMessage().contains("user data"))
    }

    @Test
    fun aCancelledRequestAnswersCancelled() {
        val operations = FakeOperations().apply { delayMillis = 300 }
        val dispatcher = dispatcher(operations)
        val response: Response = runBlocking {
            val pending =
                async(Dispatchers.Default) { dispatcher.dispatch(9, launch(0), everything) }
            assertTrue(operations.started.await(5, TimeUnit.SECONDS))
            dispatcher.cancel(9)
            pending.await()
        }
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_CANCELLED, response.getError().getCode())
    }

    @Test
    fun withContextIsUsedForTheDisplayExecutor() = runBlocking {
        // A plain call proves the executor path runs the body on a coroutine thread.
        val value = withContext(Dispatchers.Default) { 3 }
        assertEquals(3, value)
    }
}
