package io.apkrun.guest.daemon

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Test

class PackageChangeMonitorTest {
    @Test
    fun packageBroadcastsCollapseReplacementAndReportCurrentVersions() {
        val output = ByteArrayOutputStream()
        val events = EventBus().apply { attach(FrameWriter(output)) }
        val monitor =
            PackageChangeMonitor(events) { packageName ->
                if (packageName == "io.example.app") 8L else null
            }

        monitor.onPackageChanged("android.intent.action.PACKAGE_ADDED", "io.example.app")
        monitor.onPackageChanged(
            "android.intent.action.PACKAGE_ADDED",
            "io.example.app",
            replacing = true,
        )
        monitor.onPackageChanged("android.intent.action.PACKAGE_REPLACED", "io.example.app")
        monitor.onPackageChanged(
            "android.intent.action.PACKAGE_REMOVED",
            "io.example.app",
            replacing = true,
        )
        monitor.onPackageChanged("android.intent.action.PACKAGE_REMOVED", "io.example.app")
        monitor.onPackageChanged("android.intent.action.PACKAGE_ADDED", "android")

        val changes = readEvents(output)

        assertEquals(3, changes.size)
        assertEquals(
            io.apkrun.guest.protocol.v1.PackageChangeKind.PACKAGE_CHANGE_KIND_ADDED,
            changes[0].packageChanged.kind,
        )
        assertEquals(8L, changes[1].packageChanged.versionCode)
        assertEquals(
            io.apkrun.guest.protocol.v1.PackageChangeKind.PACKAGE_CHANGE_KIND_REPLACED,
            changes[1].packageChanged.kind,
        )
        assertEquals(
            io.apkrun.guest.protocol.v1.PackageChangeKind.PACKAGE_CHANGE_KIND_REMOVED,
            changes[2].packageChanged.kind,
        )
        assertEquals(0L, changes[2].packageChanged.versionCode)
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
