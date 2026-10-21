package io.apkrun.guest.daemon

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.lang.reflect.Method
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private interface FakeActivityController {
    fun appCrashed(processName: String, pid: Int, shortMessage: String): Boolean

    fun appNotResponding(processName: String, pid: Int, processStats: String): Int
}

class ActivityControllerMonitorTest {
    @Test
    fun failedControllerSetupDisablesHealthAndNamesMissingMethodInStartupDiagnostic() {
        var diagnostic: String? = null
        val monitor =
            ActivityControllerMonitor(
                events = EventBus(),
                setActivityController = { throw IllegalStateException("hook unavailable") },
                controllerFactory = { Any() },
                missingControllerMethods = { listOf("activity.setActivityController") },
                warning = { diagnostic = it },
            )

        monitor.start()

        assertEquals(false, monitor.available)
        assertEquals(
            "app crash and ANR monitoring is unavailable: missing activity.setActivityController",
            diagnostic,
        )
    }

    @Test
    fun crashAndAnrCallbacksBecomeBoundedPackageEventsWithoutAffectingAndroid() {
        val output = ByteArrayOutputStream()
        val events = EventBus().apply { attach(FrameWriter(output)) }
        val queuedCallbacks = mutableListOf<() -> Unit>()
        var callback: ((Method, Array<Any?>) -> Any?)? = null
        val monitor =
            ActivityControllerMonitor(
                events = events,
                postCallback = { queuedCallbacks.add(it) },
                setActivityController = {},
                controllerFactory = {
                    callback = it
                    Any()
                },
            )
        monitor.start()
        val crash =
            FakeActivityController::class
                .java
                .getMethod(
                    "appCrashed",
                    String::class.java,
                    Int::class.javaPrimitiveType,
                    String::class.java,
                )
        val anr =
            FakeActivityController::class
                .java
                .getMethod(
                    "appNotResponding",
                    String::class.java,
                    Int::class.javaPrimitiveType,
                    String::class.java,
                )

        assertTrue(monitor.available)
        assertEquals(
            false,
            callback?.invoke(crash, arrayOf("com.example.app:worker", 42, "crashed\nstack")),
        )
        assertEquals(0, callback?.invoke(anr, arrayOf("com.example.app", 43, "stats")))
        assertEquals(0, output.size())
        queuedCallbacks.forEach { it() }
        val processEvents = readEvents(output)

        assertEquals("com.example.app", processEvents[0].appProcessEvent.getPackage())
        assertEquals(42, processEvents[0].appProcessEvent.pid)
        assertEquals("crashed", processEvents[0].appProcessEvent.shortMessage)
        assertEquals(
            io.apkrun.guest.protocol.v1.AppProcessEventKind.APP_PROCESS_EVENT_KIND_CRASH,
            processEvents[0].appProcessEvent.kind,
        )
        assertEquals(
            io.apkrun.guest.protocol.v1.AppProcessEventKind.APP_PROCESS_EVENT_KIND_ANR,
            processEvents[1].appProcessEvent.kind,
        )
    }

    private fun readEvents(output: ByteArrayOutputStream) =
        FrameReader(ByteArrayInputStream(output.toByteArray())).let { reader ->
            buildList {
                while (true) {
                    try {
                        add(reader.next().event)
                    } catch (_: EOFException) {
                        break
                    }
                }
            }
        }
}
