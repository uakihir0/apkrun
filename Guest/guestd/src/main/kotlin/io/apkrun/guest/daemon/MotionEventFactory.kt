package io.apkrun.guest.daemon

import android.view.InputEvent
import android.view.MotionEvent
import io.apkrun.guest.runtime.SystemServices
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method

/**
 * The fields of one MotionEvent that the injector plans (input.md §4.1, §7.3). The planner builds
 * these values in plain Kotlin, so the JVM tests check them without the android.jar stubs (decision
 * D8). [MotionEventFactory] turns them into a framework event.
 */
data class MotionSpec(
    val action: Int,
    val downTime: Long,
    val eventTime: Long,
    val source: Int,
    val toolType: Int,
    val pointerId: Int,
    val x: Float,
    val y: Float,
    val pressure: Float,
    val size: Float,
    /** The button of a button action (ACTION_BUTTON_PRESS and ACTION_BUTTON_RELEASE), or 0. */
    val actionButton: Int,
    /** The MotionEvent button state bits after the action. */
    val buttonState: Int,
    /** The axis values of the pointer, by MotionEvent.AXIS_* constant. */
    val axes: Map<Int, Float>,
)

/**
 * Builds the framework event of a [MotionSpec]. The value is opaque to the planner: the real
 * implementation returns a `MotionEvent`, and a test returns a recording object.
 */
interface MotionEventFactory {
    /** Builds the event of [spec]. Throws [InputFailure] when the framework refuses it. */
    fun create(spec: MotionSpec): Any
}

/**
 * The framework calls of the injector: the display of an event, its injection, and its release. The
 * real implementation is [AndroidInjectionSink].
 */
interface InjectionSink {
    /** Sets the display of [event] (hidden `InputEvent.setDisplayId`, decision D7). */
    fun setDisplayId(event: Any, displayId: Int)

    /**
     * Injects [event] asynchronously (`INJECT_INPUT_EVENT_MODE_ASYNC`). Returns false when the
     * framework refused it. A call that throws counts as a refusal to the injector.
     */
    fun inject(event: Any): Boolean

    /** Releases [event] after its injection. */
    fun recycle(event: Any)
}

/**
 * The real event factory. It uses the public `MotionEvent.obtain` overload, which takes the pointer
 * arrays, the button state, the source, and the metadata. The public API has no setter for the
 * action button, so [setActionButton] reaches the hidden `MotionEvent.setActionButton` by
 * reflection.
 */
object AndroidMotionEventFactory : MotionEventFactory {
    /** The precision of the injected coordinates: one display pixel. */
    private const val PRECISION = 1f

    /** Injected events carry no meta state, device, edge flags, or flags. */
    private const val META_STATE = 0
    private const val DEVICE_ID = 0
    private const val EDGE_FLAGS = 0
    private const val FLAGS = 0

    /** `MotionEvent.obtain` with one pointer. */
    private const val POINTER_COUNT = 1

    private val setActionButtonMethod: Method? by lazy {
        try {
            MotionEvent::class.java.getMethod("setActionButton", Int::class.javaPrimitiveType!!)
        } catch (error: NoSuchMethodException) {
            null
        }
    }

    override fun create(spec: MotionSpec): Any {
        val properties =
            arrayOf(
                MotionEvent.PointerProperties().apply {
                    id = spec.pointerId
                    toolType = spec.toolType
                }
            )
        val coords =
            arrayOf(
                MotionEvent.PointerCoords().apply {
                    x = spec.x
                    y = spec.y
                    pressure = spec.pressure
                    size = spec.size
                    for ((axis, value) in spec.axes) {
                        setAxisValue(axis, value)
                    }
                }
            )
        val event =
            MotionEvent.obtain(
                spec.downTime,
                spec.eventTime,
                spec.action,
                POINTER_COUNT,
                properties,
                coords,
                META_STATE,
                spec.buttonState,
                PRECISION,
                PRECISION,
                DEVICE_ID,
                EDGE_FLAGS,
                spec.source,
                FLAGS,
            )
        if (spec.actionButton != 0) {
            try {
                setActionButton(event, spec.actionButton)
            } catch (failure: InputFailure) {
                event.recycle()
                throw failure
            }
        }
        return event
    }

    private fun setActionButton(event: MotionEvent, button: Int) {
        val method =
            setActionButtonMethod
                ?: throw InputFailure(InputFailureCode.SET_ACTION_BUTTON_UNAVAILABLE)
        try {
            method.invoke(event, button)
        } catch (error: InvocationTargetException) {
            throw InputFailure(InputFailureCode.EVENT_NOT_BUILT, error.targetException)
        } catch (error: ReflectiveOperationException) {
            throw InputFailure(InputFailureCode.EVENT_NOT_BUILT, error)
        }
    }
}

/**
 * The real injection sink. `setDisplayId` is the hidden `InputEvent` method, found by reflection
 * (decision D7). Injection goes through the `InputManager` wrapper of [SystemServices], which
 * resolves `injectInputEvent` once.
 */
object AndroidInjectionSink : InjectionSink {
    /** `INJECT_INPUT_EVENT_MODE_ASYNC`: the call returns once the event is queued. */
    private const val INJECT_INPUT_EVENT_MODE_ASYNC = 0

    private val setDisplayIdMethod: Method? by lazy {
        try {
            InputEvent::class.java.getMethod("setDisplayId", Int::class.javaPrimitiveType!!)
        } catch (error: NoSuchMethodException) {
            null
        }
    }

    override fun setDisplayId(event: Any, displayId: Int) {
        val method =
            setDisplayIdMethod ?: throw InputFailure(InputFailureCode.SET_DISPLAY_ID_UNAVAILABLE)
        try {
            method.invoke(event, displayId)
        } catch (error: InvocationTargetException) {
            throw InputFailure(InputFailureCode.SET_DISPLAY_ID_FAILED, error.targetException)
        } catch (error: ReflectiveOperationException) {
            throw InputFailure(InputFailureCode.SET_DISPLAY_ID_FAILED, error)
        }
    }

    override fun inject(event: Any): Boolean {
        val accepted =
            SystemServices.input.call("injectInputEvent", event, INJECT_INPUT_EVENT_MODE_ASYNC)
        return accepted as? Boolean ?: false
    }

    override fun recycle(event: Any) {
        (event as? MotionEvent)?.recycle()
    }
}
