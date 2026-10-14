package io.apkrun.fixture.hellotext

import android.content.Context
import android.os.SystemClock
import android.util.AttributeSet
import android.view.MotionEvent
import android.widget.Button

/**
 * The debug fixture observes dispatch without consuming or changing Android's normal touch
 * handling.
 */
class TraceableCounterButton
@JvmOverloads
constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = android.R.attr.buttonStyle,
) : Button(context, attrs, defStyleAttr) {
    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        val action =
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> TouchTraceAction.DOWN
                MotionEvent.ACTION_UP -> TouchTraceAction.UP
                MotionEvent.ACTION_CANCEL -> TouchTraceAction.CANCEL
                else -> null
            }
        if (action != null && CounterTouchTrace.isRecording()) {
            CounterTouchTrace.recordTouch(SystemClock.elapsedRealtimeNanos(), action, isPressed)
        }
        return super.dispatchTouchEvent(event)
    }

    override fun setPressed(pressed: Boolean) {
        super.setPressed(pressed)
        if (CounterTouchTrace.isRecording()) {
            CounterTouchTrace.recordPressed(SystemClock.elapsedRealtimeNanos(), isPressed)
        }
    }
}
