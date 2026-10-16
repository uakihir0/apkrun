package io.apkrun.fixture.hellotext

import android.content.Context
import android.os.SystemClock
import android.util.AttributeSet
import android.widget.Button

/** Adds pressed-state records only while the explicit debug touch trace is active. */
class TraceableCounterButton
@JvmOverloads
constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = android.R.attr.buttonStyle,
) : Button(context, attrs, defStyleAttr) {
    private val captureLineage = TouchTraceCaptureLineage()

    fun setTraceCaptureToken(token: TouchTraceCaptureToken?) {
        captureLineage.setActiveCaptureToken(token)
    }

    fun clearTraceCaptureTokens() {
        captureLineage.clear()
    }

    /** Called only by the capture-only OnTouchListener, before Button handles this event. */
    fun noteTraceTouchAction(action: TouchTraceAction) {
        val terminalGestureGeneration = captureLineage.observeTouchAction(action) ?: return
        post {
            captureLineage.clearGesture(terminalGestureGeneration)
        }
    }

    override fun setPressed(pressed: Boolean) {
        val captureToken = captureLineage.captureTokenForPressedTransition(pressed)
        val pressedBefore = isPressed
        super.setPressed(pressed)
        val pressedAfter = isPressed
        if (pressedBefore != pressedAfter) {
            if (captureToken != null) {
                DebugTouchTraceSession.recordPressedTransition(
                    captureToken = captureToken,
                    sampledAtElapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos(),
                    requestedPressed = pressed,
                    pressedBefore = pressedBefore,
                    pressedAfter = pressedAfter,
                )
            }
            captureLineage.recordPressedState(pressedAfter, captureToken)
        }
    }
}
