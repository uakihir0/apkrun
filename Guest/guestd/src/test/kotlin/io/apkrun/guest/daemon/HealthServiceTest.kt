package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.GuestError
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InputCounters
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HealthServiceTest {
    @Test
    fun healthSnapshotCombinesRuntimeAndFrameworkFacts() {
        var uptime = 100L
        val service =
            healthService(
                uptimeMillis = { uptime },
                memory = {
                    GuestMemorySnapshot(totalKb = 4096, availableKb = 1024, lowMemory = false)
                },
            )
        uptime = 345L
        val previousFailure =
            GuestError.newBuilder()
                .setCode(GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT)
                .setMessage("operation timed out")
                .build()
        service.recordFailure(previousFailure)

        val health = service.getHealth()

        assertEquals(245L, health.agentUptimeMs)
        assertEquals(AgentMode.AGENT_MODE_DEVELOPMENT_SHELL, health.mode)
        assertEquals(3, health.displaysCount)
        assertTrue(health.imeSelected)
        assertFalse(health.notificationListenerEnabled)
        assertTrue(health.adbEnabled)
        assertEquals(4096L, health.memory.totalKb)
        assertEquals(1024L, health.memory.availableKb)
        assertFalse(health.memory.lowMemory)
        assertEquals(14L, health.input.batches)
        assertEquals(2, health.openSessions)
        assertEquals(previousFailure, health.lastError)
    }

    @Test
    fun lowMemoryCallbackPublishesOneWarningPerEpisode() {
        val output = ByteArrayOutputStream()
        val events = EventBus().apply { attach(FrameWriter(output)) }
        var registered: (() -> Unit)? = null
        val queuedCallbacks = mutableListOf<() -> Unit>()
        var currentMemory = GuestMemorySnapshot(1024, 128, lowMemory = false)
        val service =
            healthService(
                events = events,
                memory = { currentMemory },
                registerLowMemoryCallback = { registered = it },
                postCallback = { queuedCallbacks.add(it) },
            )

        service.start()
        registered?.invoke()
        registered?.invoke()
        assertEquals(0, output.size())
        queuedCallbacks.forEach { it() }
        queuedCallbacks.clear()
        currentMemory = currentMemory.copy(lowMemory = true)
        service.getHealth()
        currentMemory = currentMemory.copy(lowMemory = false)
        service.getHealth()
        registered?.invoke()
        queuedCallbacks.forEach { it() }

        val warnings = readEvents(output).filter { it.kindCase == Event.KindCase.HEALTH_WARNING }
        assertEquals(2, warnings.size)
        assertEquals(
            io.apkrun.guest.protocol.v1.HealthWarningKind.HEALTH_WARNING_KIND_LOW_MEMORY,
            warnings.first().healthWarning.kind,
        )
    }

    @Test
    fun healthSnapshotReportsMissingSystemMethods() {
        val health =
            healthService(
                    memory = {
                        GuestMemorySnapshot(totalKb = 1024, availableKb = 512, lowMemory = false)
                    },
                    missingMethods = { listOf("power.shutdown", "activity_task.getTasks") },
                )
                .getHealth()

        assertTrue(health.hasLastError())
        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
            health.lastError.code,
        )
        assertEquals(
            "activity_task.getTasks,power.shutdown",
            health.lastError.detailMap["missing_methods"],
        )
    }

    @Test
    fun healthSnapshotReportsConfiguredTestImageFailure() {
        val health =
            healthService(
                    memory = {
                        GuestMemorySnapshot(totalKb = 1024, availableKb = 512, lowMemory = false)
                    },
                    forcedFailure = { true },
                )
                .getHealth()

        assertTrue(health.hasLastError())
        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_INTERNAL,
            health.lastError.code,
        )
        assertEquals("test image requested a health failure", health.lastError.message)
    }

    private fun healthService(
        events: EventBus = EventBus(),
        uptimeMillis: () -> Long = { 100L },
        memory: () -> GuestMemorySnapshot,
        registerLowMemoryCallback: ((() -> Unit) -> Unit) = {},
        postCallback: ((() -> Unit) -> Unit) = { work -> work() },
        missingMethods: () -> List<String> = { emptyList() },
        forcedFailure: () -> Boolean = { false },
    ) =
        HealthService(
            events = events,
            uptimeMillis = uptimeMillis,
            mode = { AgentMode.AGENT_MODE_DEVELOPMENT_SHELL },
            displaysCount = { 3 },
            imeSelected = { true },
            notificationListenerEnabled = { false },
            adbEnabled = { true },
            memory = memory,
            inputCounters = {
                InputCounters.newBuilder().setBatches(14).setEventsInjected(28).build()
            },
            openSessions = { 2 },
            registerLowMemoryCallback = registerLowMemoryCallback,
            postCallback = postCallback,
            missingMethods = missingMethods,
            forcedFailure = forcedFailure,
        )

    private fun readEvents(output: ByteArrayOutputStream): List<Event> {
        val reader = FrameReader(ByteArrayInputStream(output.toByteArray()))
        val result = mutableListOf<Event>()
        while (true) {
            try {
                result += reader.next().event
            } catch (_: EOFException) {
                return result
            }
        }
    }
}
