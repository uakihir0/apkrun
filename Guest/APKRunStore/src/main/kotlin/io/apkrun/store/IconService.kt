package io.apkrun.store

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.Drawable
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.BulkKind
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.IconKind
import io.apkrun.guest.protocol.v1.IconLayer
import io.apkrun.guest.protocol.v1.IconResult
import io.apkrun.guest.protocol.v1.IconRole
import io.apkrun.guest.protocol.v1.RenderIcon
import java.io.ByteArrayOutputStream

/** A rendered icon layer: its role and the PNG payload (wrapper.md §8.1). */
data class RenderedIconLayer(val role: IconRole, val png: ByteArray)

/**
 * Renders a package's icon layers at [sizePx] (wrapper.md §8.1): each layer of an adaptive icon on
 * the full 108 dp canvas, or a legacy icon's highest-density bitmap, as PNGs.
 */
interface IconRenderer {
    /** The kind and layers of [packageName]'s icon. Throws [GuestFailure] `NOT_FOUND`. */
    fun render(packageName: String, sizePx: Int): Pair<IconKind, List<RenderedIconLayer>>
}

/** The device renderer over PackageManager. */
class AndroidIconRenderer(private val context: Context) : IconRenderer {
    override fun render(packageName: String, sizePx: Int): Pair<IconKind, List<RenderedIconLayer>> {
        val info =
            try {
                context.packageManager.getApplicationInfo(packageName, 0)
            } catch (notFound: PackageManager.NameNotFoundException) {
                throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "the package is not installed",
                )
            }
        return when (val icon = info.loadUnbadgedIcon(context.packageManager)) {
            is AdaptiveIconDrawable -> renderAdaptive(icon, sizePx)
            else ->
                IconKind.ICON_KIND_LEGACY to
                    listOf(RenderedIconLayer(IconRole.ICON_ROLE_LEGACY, png(icon, sizePx)))
        }
    }

    private fun renderAdaptive(
        icon: AdaptiveIconDrawable,
        sizePx: Int,
    ): Pair<IconKind, List<RenderedIconLayer>> {
        val layers =
            listOfNotNull(
                icon.background?.let {
                    RenderedIconLayer(IconRole.ICON_ROLE_BACKGROUND, png(it, sizePx))
                },
                icon.foreground?.let {
                    RenderedIconLayer(IconRole.ICON_ROLE_FOREGROUND, png(it, sizePx))
                },
                icon.monochrome?.let {
                    RenderedIconLayer(IconRole.ICON_ROLE_MONOCHROME, png(it, sizePx))
                },
            )
        if (layers.isEmpty()) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE,
                "the icon has no drawable layers",
            )
        }
        return IconKind.ICON_KIND_ADAPTIVE to layers
    }

    /** Draws [drawable] onto a sizePx canvas, unmasked, as PNG bytes. */
    private fun png(drawable: Drawable, sizePx: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, sizePx, sizePx)
        drawable.draw(canvas)
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }
}

/**
 * `RenderIcon` (store.icon.v1, guest-protocol.md §11.1): renders the icon, streams each layer on
 * the artifact connection as an `ICON_LAYER` bulk transfer, and answers the layer's transfer IDs.
 */
class IconService(
    private val renderer: IconRenderer,
    private val transfers: StoreTransfers,
) {
    fun renderIcon(request: RenderIcon): IconResult {
        val (kind, layers) = renderer.render(request.`package`, request.sizePx)
        val result = IconResult.newBuilder().setKind(kind)
        for (layer in layers) {
            val name = layer.role.name.removePrefix("ICON_ROLE_").lowercase() + ".png"
            val transferId =
                transfers.send(BulkKind.BULK_KIND_ICON_LAYER, name, "image/png", layer.png)
                    ?: throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE,
                        "the artifact channel is not open",
                    )
            result.addLayers(IconLayer.newBuilder().setRole(layer.role).setTransferId(transferId))
        }
        return result.build()
    }
}
