package io.apkrun.fixture.hellotext

import android.content.Context
import android.util.AttributeSet
import android.widget.Button

/** The release fixture uses platform Button behavior without diagnostic touch overrides. */
class TraceableCounterButton
@JvmOverloads
constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = android.R.attr.buttonStyle,
) : Button(context, attrs, defStyleAttr) {
    fun setTraceCaptureToken(token: TouchTraceCaptureToken?) = Unit

    fun noteTraceTouchAction(action: TouchTraceAction) = Unit

    fun clearTraceCaptureTokens() = Unit
}
