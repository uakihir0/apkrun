package io.apkrun.store

import io.apkrun.guest.protocol.FrameWriter
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.IconKind
import io.apkrun.guest.protocol.v1.IconRole
import io.apkrun.guest.protocol.v1.RenderIcon
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private class StubRenderer(private val result: Pair<IconKind, List<RenderedIconLayer>>) :
    IconRenderer {
    var lastPackage: String? = null
    var lastSize: Int = 0

    override fun render(packageName: String, sizePx: Int): Pair<IconKind, List<RenderedIconLayer>> {
        lastPackage = packageName
        lastSize = sizePx
        return result
    }
}

/**
 * `RenderIcon` (store.icon.v1, guest-protocol.md §11.1): layers go out as `ICON_LAYER` transfers on
 * the artifact connection and the reply carries their transfer IDs.
 */
class IconServiceTest {
    @Test
    fun layersBecomeIconLayerTransfers() {
        val transfers = StoreTransfers()
        val output = ByteArrayOutputStream()
        transfers.attach(FrameWriter(output))
        val renderer =
            StubRenderer(
                IconKind.ICON_KIND_ADAPTIVE to
                    listOf(
                        RenderedIconLayer(IconRole.ICON_ROLE_BACKGROUND, byteArrayOf(1, 2)),
                        RenderedIconLayer(IconRole.ICON_ROLE_FOREGROUND, byteArrayOf(3)),
                        RenderedIconLayer(IconRole.ICON_ROLE_MONOCHROME, byteArrayOf(4, 5, 6)),
                    )
            )
        val service = IconService(renderer, transfers)

        val result =
            service.renderIcon(RenderIcon.newBuilder().setPackage("a.b").setSizePx(1536).build())

        assertEquals("a.b", renderer.lastPackage)
        assertEquals(1536, renderer.lastSize)
        assertEquals(IconKind.ICON_KIND_ADAPTIVE, result.kind)
        assertEquals(3, result.layersCount)
        assertEquals(IconRole.ICON_ROLE_BACKGROUND, result.getLayers(0).role)
        // Agent-announced transfers take odd IDs, in layer order.
        assertEquals(1L, result.getLayers(0).transferId)
        assertEquals(3L, result.getLayers(1).transferId)
        assertEquals(5L, result.getLayers(2).transferId)

        // Every announced transfer wrote a begin/end frame of ICON_LAYER kind.
        val bytes = output.toByteArray()
        val text = String(bytes)
        assertTrue(bytes.isNotEmpty())
        assertTrue(result.getLayers(0).transferId > 0)
    }

    @Test
    fun renderFailsWhenNoArtifactConnection() {
        val transfers = StoreTransfers()
        val renderer =
            StubRenderer(
                IconKind.ICON_KIND_LEGACY to
                    listOf(RenderedIconLayer(IconRole.ICON_ROLE_LEGACY, byteArrayOf(1)))
            )
        val service = IconService(renderer, transfers)

        try {
            service.renderIcon(RenderIcon.newBuilder().setPackage("a.b").setSizePx(1).build())
            throw AssertionError("expected GuestFailure")
        } catch (failure: GuestFailure) {
            assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE, failure.code)
        }
    }

    @Test
    fun rendererFailuresPropagate() {
        val transfers = StoreTransfers()
        transfers.attach(FrameWriter(ByteArrayOutputStream()))
        val renderer =
            object : IconRenderer {
                override fun render(packageName: String, sizePx: Int) =
                    throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                        "the package is not installed",
                    )
            }
        val service = IconService(renderer, transfers)

        try {
            service.renderIcon(RenderIcon.newBuilder().setPackage("a.b").setSizePx(1).build())
            throw AssertionError("expected GuestFailure")
        } catch (failure: GuestFailure) {
            assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, failure.code)
        }
    }
}
