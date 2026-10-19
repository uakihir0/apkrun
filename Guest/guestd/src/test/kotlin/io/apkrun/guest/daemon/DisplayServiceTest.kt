package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.DeviceProductInfo
import io.apkrun.guest.protocol.v1.DisplayInfo
import io.apkrun.guest.protocol.v1.DisplayMode
import io.apkrun.guest.protocol.v1.DisplayState
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ImePolicy
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class DisplayServiceTest {
    @Test
    fun displayAddChangeAndRemoveEventsPreserveProductInfo() {
        val displays = mutableMapOf(3 to display(3, density = 213, product = productInfo()))
        val (service, output) = service(displays)

        service.refresh()
        displays[3] = display(3, density = 320, product = productInfo())
        service.refresh()
        displays.clear()
        service.refresh()

        val events = events(output)
        assertEquals(
            listOf(
                Event.KindCase.DISPLAY_ADDED,
                Event.KindCase.DISPLAY_CHANGED,
                Event.KindCase.DISPLAY_REMOVED,
            ),
            events.map { it.kindCase },
        )
        assertEquals(productInfo(), events[0].displayAdded.product)
        assertEquals(productInfo(), events[1].displayChanged.product)
        assertEquals(3, events[2].displayRemoved.displayId)
    }

    @Test
    fun setDisplayPolicySucceedsWhenAndroidReportsTheRequestedDensity() {
        val displays = mutableMapOf(3 to display(3, density = 213))
        val (service) = service(displays, applyRequestedDensity = true)

        service.applyPolicy(policy(3, density = 320))

        assertEquals(320, displays.getValue(3).densityDpi)
    }

    @Test
    fun setDisplayPolicyFailsWhenAndroidDoesNotApplyTheRequestedDensity() {
        val displays = mutableMapOf(3 to display(3, density = 213))
        val (service) = service(displays, applyRequestedDensity = false)

        val failure =
            assertThrows(GuestFailure::class.java) { service.applyPolicy(policy(3, density = 320)) }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION, failure.code)
        assertEquals("320", failure.detail["requested_density_dpi"])
        assertEquals("213", failure.detail["actual_density_dpi"])
    }

    private fun service(
        displays: MutableMap<Int, DisplayInfo>,
        applyRequestedDensity: Boolean = true,
    ): Pair<DisplayService, ByteArrayOutputStream> {
        val output = ByteArrayOutputStream()
        val events = EventBus()
        events.attach(FrameWriter(output))
        val service =
            DisplayService(
                events = events,
                callbacks = {},
                readDisplayInventory = { displays.toMap() },
                forceDensity = { displayId, density, _ ->
                    if (applyRequestedDensity) {
                        displays[displayId] =
                            displays.getValue(displayId).toBuilder().setDensityDpi(density).build()
                    }
                },
                applyImePolicy = { _, _ -> },
            )
        return service to output
    }

    private fun events(output: ByteArrayOutputStream): List<Event> {
        val reader = FrameReader(ByteArrayInputStream(output.toByteArray()))
        val events = mutableListOf<Event>()
        while (true) {
            try {
                events += reader.next().event
            } catch (_: EOFException) {
                return events
            }
        }
    }

    private fun policy(displayId: Int, density: Int): SetDisplayPolicy =
        SetDisplayPolicy.newBuilder()
            .setDisplayId(displayId)
            .setDensityDpi(density)
            .setImePolicy(ImePolicy.IME_POLICY_LOCAL)
            .build()

    private fun display(
        displayId: Int,
        density: Int,
        product: DeviceProductInfo? = null,
    ): DisplayInfo {
        val builder =
            DisplayInfo.newBuilder()
                .setDisplayId(displayId)
                .setUniqueId("local:$displayId")
                .setName("APKRun display")
                .setMode(
                    DisplayMode.newBuilder().setWidthPx(960).setHeightPx(1700).setRefreshHz(60f)
                )
                .setDensityDpi(density)
                .setRotation(0)
                .setState(DisplayState.DISPLAY_STATE_ON)
        product?.let(builder::setProduct)
        return builder.build()
    }

    private fun productInfo(): DeviceProductInfo =
        DeviceProductInfo.newBuilder()
            .setManufacturerPnpId("APK")
            .setProductId(3)
            .setModelYear(2026)
            .setName("APKRun scanout")
            .build()
}
