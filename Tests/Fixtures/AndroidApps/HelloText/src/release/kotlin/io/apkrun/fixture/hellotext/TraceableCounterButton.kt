package io.apkrun.fixture.hellotext

import android.content.Context
import android.util.AttributeSet
import android.widget.Button

/** The release fixture uses the platform Button with no diagnostic touch overrides. */
class TraceableCounterButton
@JvmOverloads
constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = android.R.attr.buttonStyle,
) : Button(context, attrs, defStyleAttr)
