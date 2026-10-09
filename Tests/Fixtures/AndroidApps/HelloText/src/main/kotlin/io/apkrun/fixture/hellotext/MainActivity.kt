package io.apkrun.fixture.hellotext

import android.app.Activity
import android.os.Bundle
import android.util.Log
import android.view.ContextMenu
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.widget.Button
import android.widget.TextView

/**
 * The only Activity of HelloText. It shows a counter that persists across process restarts. Each click
 * logs `APKRUN-FIXTURE: click <n>`, and a long press on the target text offers a reset.
 */
class MainActivity : Activity() {
    private lateinit var counter: CounterStore
    private lateinit var counterText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        counter = CounterStore(PreferencesKeyValueStore(getSharedPreferences(PREFERENCES, MODE_PRIVATE)))
        counterText = findViewById(R.id.counter_text)
        showCount(counter.current())
        findViewById<Button>(R.id.increment_button).setOnClickListener { click() }
        registerForContextMenu(findViewById<TextView>(R.id.context_target))
    }

    private fun click() {
        val value = counter.increment()
        Log.i(LOG_TAG, "click $value")
        showCount(value)
    }

    private fun showCount(value: Int) {
        counterText.text = getString(R.string.counter_format, value)
    }

    override fun onCreateContextMenu(menu: ContextMenu, v: View, menuInfo: ContextMenu.ContextMenuInfo?) {
        super.onCreateContextMenu(menu, v, menuInfo)
        menu.add(Menu.NONE, MENU_RESET, Menu.NONE, R.string.reset_counter)
    }

    override fun onContextItemSelected(item: MenuItem): Boolean {
        if (item.itemId != MENU_RESET) {
            return super.onContextItemSelected(item)
        }
        counter.reset()
        showCount(0)
        return true
    }

    companion object {
        /** The SharedPreferences file of the counter. */
        const val PREFERENCES = "hellotext"

        /** The logcat tag of the click lines. */
        const val LOG_TAG = "APKRUN-FIXTURE"

        private const val MENU_RESET = 1
    }
}
