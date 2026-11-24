package io.apkrun.fixture.hellolinks

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.Toast

/**
 * The links fixture of #82 (test-strategy.md §4.2): buttons that open each link
 * case of desktop-integration.md §7 — https, mailto, a Custom Tabs-style VIEW
 * with extras, `javascript:`, `intent:`, and a link fired while the app is in
 * the background (the 8 s delay lets the T2 test send the app home first).
 */
class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        layout.addView(button("Open https://example.com/") { view("https://example.com/") })
        layout.addView(button("Open mailto") { view("mailto:test@example.com") })
        layout.addView(
            button("Open Custom Tab style") {
                val intent = view("https://example.com/custom-tab")
                intent.putExtra("android.support.customtabs.extra.SESSION", Bundle())
                intent.putExtra("android.support.customtabs.extra.TOOLBAR_COLOR", 0xFF3F51B5.toInt())
            }
        )
        layout.addView(button("Open javascript: link") { view("javascript:alert(1)") })
        layout.addView(
            button("Open intent: link") {
                view("intent://scan/#Intent;scheme=zxing;action=com.google.zxing.client.android.SCAN;end")
            }
        )
        layout.addView(
            button("Open link after 8 s") {
                handler.postDelayed({ view("https://example.com/background") }, 8_000)
            }
        )
        setContentView(layout)
    }

    private fun button(label: String, action: () -> Unit): Button =
        Button(this).apply {
            text = label
            setOnClickListener { action() }
        }

    private fun view(url: String): Intent {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        try {
            startActivity(intent)
        } catch (error: ActivityNotFoundException) {
            Toast.makeText(this, "no activity for $url", Toast.LENGTH_LONG).show()
        }
        return intent
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}
