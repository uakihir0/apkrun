package io.apkrun.guest.daemon

import android.view.InputDevice
import android.view.KeyCharacterMap
import android.view.KeyEvent

/**
 * The fields of one KeyEvent that the injector plans (input.md §5.2, §7.3). As [MotionSpec] does
 * for motion events, it keeps the planner in plain Kotlin, so the JVM tests check every field
 * (decision D8).
 */
data class KeySpec(
    /** `KeyEvent.ACTION_DOWN` or `KeyEvent.ACTION_UP`. */
    val action: Int,
    val downTime: Long,
    val eventTime: Long,
    /** The `KeyEvent.KEYCODE_*` value. */
    val keyCode: Int,
    /** The number of repeats of a held key, 0 for the first DOWN and for every UP. */
    val repeatCount: Int,
    /** The `KeyEvent.META_*` bits of the event. */
    val metaState: Int,
)

/**
 * Builds the framework event of a [KeySpec]. Throws [InputFailure] when the framework refuses it.
 */
interface KeyEventFactory {
    fun create(spec: KeySpec): Any
}

/**
 * The real key event factory. The events are on the virtual keyboard device, whose character map is
 * the US layout (input.md §5.1, §10). Android then gives the characters of the key codes, so the
 * injector sends no characters.
 */
object AndroidKeyEventFactory : KeyEventFactory {
    /** Injected key events have no scan code and no flags. */
    private const val SCAN_CODE = 0
    private const val FLAGS = 0

    override fun create(spec: KeySpec): Any =
        KeyEvent(
            spec.downTime,
            spec.eventTime,
            spec.action,
            spec.keyCode,
            spec.repeatCount,
            spec.metaState,
            KeyCharacterMap.VIRTUAL_KEYBOARD,
            SCAN_CODE,
            FLAGS,
            InputDevice.SOURCE_KEYBOARD,
        )
}
