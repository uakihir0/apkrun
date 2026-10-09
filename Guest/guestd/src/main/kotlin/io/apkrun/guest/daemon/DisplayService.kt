package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.DeviceProductInfo
import io.apkrun.guest.protocol.v1.DisplayInfo
import io.apkrun.guest.protocol.v1.DisplayMode
import io.apkrun.guest.protocol.v1.DisplayRemoved
import io.apkrun.guest.protocol.v1.DisplayState
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ImePolicy
import io.apkrun.guest.protocol.v1.SetDisplayPolicy
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.HiddenApi
import io.apkrun.guest.runtime.ServiceMethodMissing
import io.apkrun.guest.runtime.SystemServices

/** The system user, which the density and the IME policy apply to (guest-components.md §5). */
private const val SYSTEM_USER_ID = 0

/** The largest density that the agent accepts for a display (dpi). */
private const val MAXIMUM_DENSITY_DPI = 1000

/**
 * Display events and display policy (display.v1, guest-protocol.md §8.2, guest-components.md §6.1).
 * The list of displays comes from `IDisplayManager`. A change callback refreshes it on the
 * callbacks thread, and the new list is compared with the last one, so only the displays that
 * changed produce events.
 */
class DisplayService(
    private val events: EventBus,
    /**
     * Runs a refresh on the `apkrun-callbacks` thread, so that a framework callback never waits for
     * a socket.
     */
    private val callbacks: (() -> Unit) -> Unit,
) {
    private val known = LinkedHashMap<Int, DisplayInfo>()

    /**
     * Registers the display listener and reads the first list. A missing listener only fails
     * display events.
     */
    fun start() {
        val listenerInterface =
            HiddenApi.classOrNull("android.hardware.display.IDisplayManagerCallback")
        if (listenerInterface == null) {
            AgentLog.warning("display events are unavailable: the callback interface is missing")
        } else {
            val listener =
                HiddenApi.proxy(listenerInterface) { _, _ ->
                    callbacks { refresh() }
                    null
                }
            try {
                SystemServices.display.call("registerCallback", listener)
            } catch (error: ServiceMethodMissing) {
                AgentLog.warning("display events are unavailable: ${error.method} is missing")
            }
        }
        refresh()
    }

    /** The displays that Android reports now, by display ID. */
    fun readDisplays(): Map<Int, DisplayInfo> {
        val wrapper = SystemServices.display
        val ids =
            wrapper.call("getDisplayIds", *displayIdsArguments()) as? IntArray ?: return emptyMap()
        val result = LinkedHashMap<Int, DisplayInfo>()
        for (id in ids) {
            val info = wrapper.call("getDisplayInfo", id) ?: continue
            result[id] = toProto(id, info)
        }
        return result
    }

    /** Publishes the differences between the last list and the list that Android reports now. */
    @Synchronized
    fun refresh() {
        val current = readDisplays()
        for ((id, info) in current) {
            val before = known[id]
            if (before == null) {
                events.publish { it.setDisplayAdded(info) }
            } else if (before != info) {
                events.publish { it.setDisplayChanged(info) }
            }
        }
        for (id in known.keys - current.keys) {
            events.publish { it.setDisplayRemoved(DisplayRemoved.newBuilder().setDisplayId(id)) }
        }
        known.clear()
        known.putAll(current)
    }

    /**
     * Applies the density and the IME policy of a display, with `WindowManager`. The refresh runs
     * before the answer, so the DisplayChanged event of the new density is sent before the response
     * (guest-protocol.md §6).
     */
    @Synchronized
    fun applyPolicy(request: SetDisplayPolicy) {
        val displayId = request.displayId
        if (!readDisplays().containsKey(displayId)) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the display is not known",
                mapOf("display_id" to displayId.toString()),
            )
        }
        if (request.densityDpi < 0 || request.densityDpi > MAXIMUM_DENSITY_DPI) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the density is out of range",
            )
        }
        val policy =
            imePolicyValue(request.imePolicy)
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                    "the IME policy is not set",
                )
        SystemServices.window.call(
            "setForcedDisplayDensityForUser",
            displayId,
            request.densityDpi,
            SYSTEM_USER_ID,
        )
        SystemServices.window.call("setDisplayImePolicy", displayId, policy)
        refresh()
    }

    /** The mode of a display, or null when the display is not known. */
    fun modeOf(displayId: Int): DisplayMode? = readDisplays()[displayId]?.getMode()

    private fun displayIdsArguments(): Array<Any?> =
        if (SystemServices.display.parameterCount("getDisplayIds") == 1) arrayOf(false)
        else emptyArray()

    private fun toProto(id: Int, info: Any): DisplayInfo {
        val builder =
            DisplayInfo.newBuilder()
                .setDisplayId(id)
                .setUniqueId(HiddenApi.read(info, "uniqueId") as? String ?: "")
                .setName(HiddenApi.read(info, "name") as? String ?: "")
                .setMode(
                    DisplayMode.newBuilder()
                        .setWidthPx(intField(info, "logicalWidth"))
                        .setHeightPx(intField(info, "logicalHeight"))
                        .setRefreshHz(floatField(info, "refreshRate"))
                )
                .setDensityDpi(intField(info, "logicalDensityDpi"))
                .setRotation(intField(info, "rotation"))
                .setState(stateOf(intField(info, "state")))
                .setFlags(intField(info, "flags"))
        HiddenApi.read(info, "deviceProductInfo")?.let { product ->
            builder.setProduct(
                DeviceProductInfo.newBuilder()
                    .setManufacturerPnpId(
                        HiddenApi.read(product, "manufacturerPnpId") as? String ?: ""
                    )
                    .setProductId(intField(product, "productId"))
                    .setModelYear(intField(product, "modelYear"))
                    .setName(HiddenApi.read(product, "name") as? String ?: "")
            )
        }
        return builder.build()
    }

    private fun intField(target: Any, name: String): Int =
        (HiddenApi.read(target, name) as? Number)?.toInt() ?: 0

    private fun floatField(target: Any, name: String): Float =
        (HiddenApi.read(target, name) as? Number)?.toFloat() ?: 0f

    private fun stateOf(value: Int): DisplayState =
        when (value) {
            STATE_ON -> DisplayState.DISPLAY_STATE_ON
            STATE_OFF -> DisplayState.DISPLAY_STATE_OFF
            else -> DisplayState.DISPLAY_STATE_UNKNOWN
        }

    private companion object {
        /** `Display.STATE_OFF` and `Display.STATE_ON`. */
        const val STATE_OFF = 1
        const val STATE_ON = 2

        /** `WindowManager.DISPLAY_IME_POLICY_*`. */
        fun imePolicyValue(policy: ImePolicy): Int? =
            when (policy) {
                ImePolicy.IME_POLICY_LOCAL -> 0
                ImePolicy.IME_POLICY_FALLBACK_DISPLAY -> 1
                ImePolicy.IME_POLICY_HIDE -> 2
                else -> null
            }
    }
}
