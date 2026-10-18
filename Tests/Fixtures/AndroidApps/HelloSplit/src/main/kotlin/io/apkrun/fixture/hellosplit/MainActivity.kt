package io.apkrun.fixture.hellosplit

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView

class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val nativeMessage = NativeProbe().message()
        val localizedMessage = getString(R.string.locale_message)
        Log.i("APKRUN-FIXTURE", nativeMessage)
        Log.i("APKRUN-FIXTURE", "string $localizedMessage")

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(24, 24, 24, 24)
                addView(TextView(context).apply { text = nativeMessage })
                addView(TextView(context).apply { text = localizedMessage })
                addView(ImageView(context).apply {
                    setImageResource(R.drawable.density_marker)
                    contentDescription = getString(R.string.density_marker_description)
                })
                addView(
                    Button(context).apply {
                        text = getString(R.string.open_feature)
                        setOnClickListener {
                            startActivity(
                                Intent().setClassName(
                                    this@MainActivity,
                                    "io.apkrun.fixture.hellosplit.feature.FeatureActivity"
                                )
                            )
                        }
                    }
                )
            }
        )
    }
}

private class NativeProbe {
    external fun message(): String

    companion object {
        init {
            System.loadLibrary("hellosplit")
        }
    }
}
