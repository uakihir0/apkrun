package io.apkrun.fixture.hellotext

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Bundle
import android.os.SystemClock
import android.text.Editable
import android.text.TextWatcher
import android.util.Log
import android.view.ContextMenu
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.TextView

/**
 * The main Activity of HelloText. It shows a counter that persists across process restarts. Each click
 * logs `APKRUN-FIXTURE: click <n>`. A long press on the target text logs `APKRUN-FIXTURE: contextmenu` and offers
 * a reset. The field takes the typed text, and the Details button opens the Details screen (#025). The screen logs
 * `APKRUN-FIXTURE: screen <name>` when it resumes.
 */
class MainActivity : Activity() {
    private lateinit var counter: CounterStore
    private lateinit var counterText: TextView
    private var traceDebugBuild = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        traceDebugBuild = applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        counter = openCounter(this)
        counterText = findViewById(R.id.counter_text)
        showCount(counter.current())
        val incrementButton = findViewById<Button>(R.id.increment_button)
        if (traceDebugBuild) {
            incrementButton.setOnTouchListener { view, event ->
                if (
                    !DebugTouchTraceSession.isCapturing ||
                        TouchTraceAction.fromMaskedValue(event.actionMasked) == null
                ) {
                    return@setOnTouchListener false
                }
                val inside =
                    event.x >= 0f &&
                        event.y >= 0f &&
                        event.x < view.width.toFloat() &&
                        event.y < view.height.toFloat()
                val inputSequence =
                    DebugTouchTraceSession.recordTouch(
                        eventTimeMillis = event.eventTime,
                        downTimeMillis = event.downTime,
                        action = event.actionMasked,
                        pressedBefore = view.isPressed,
                        enabled = view.isEnabled,
                        focused = view.hasFocus(),
                        inside = inside,
                        shown = view.isShown,
                    )
                if (inputSequence != null) {
                    view.postOnAnimation {
                        DebugTouchTraceSession.recordPostDispatchPressed(
                            inputSequence,
                            sampledAtUptimeMillis = SystemClock.uptimeMillis(),
                            pressed = view.isPressed,
                        )
                    }
                }
                false
            }
        }
        incrementButton.setOnClickListener { click() }
        findViewById<Button>(R.id.details_button).setOnClickListener {
            startActivity(Intent(this, DetailsActivity::class.java))
        }
        findViewById<EditText>(R.id.input_text).addTextChangedListener(
            object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit

                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) = Unit

                override fun afterTextChanged(s: Editable?) {
                    FixtureState.fieldText = s?.toString().orEmpty()
                }
            }
        )
        // Enter in the field is the editor action of the field (imeOptions actionDone). The line names the action only.
        findViewById<EditText>(R.id.input_text).setOnEditorActionListener { _, actionId, _ ->
            Log.i(LOG_TAG, "editor action $actionId")
            false
        }
        registerForContextMenu(findViewById<TextView>(R.id.context_target))
    }

    override fun onResume() {
        super.onResume()
        FixtureState.screen = FixtureState.SCREEN_MAIN
        Log.i(LOG_TAG, "screen ${FixtureState.SCREEN_MAIN}")
    }

    private fun click() {
        try {
            val value = counter.increment()
            if (traceDebugBuild) {
                DebugTouchTraceSession.recordClick(storedCounter = value, saveSucceeded = true)
            }
            Log.i(LOG_TAG, "click $value")
            showCount(value)
        } catch (failure: IllegalStateException) {
            if (traceDebugBuild) {
                DebugTouchTraceSession.recordClick(storedCounter = null, saveSucceeded = false)
            }
            Log.e(LOG_TAG, "click not saved: ${failure.message}")
        }
    }

    private fun showCount(value: Int) {
        counterText.text = getString(R.string.counter_format, value)
    }

    override fun onCreateContextMenu(menu: ContextMenu, v: View, menuInfo: ContextMenu.ContextMenuInfo?) {
        super.onCreateContextMenu(menu, v, menuInfo)
        Log.i(LOG_TAG, "contextmenu")
        menu.add(Menu.NONE, MENU_RESET, Menu.NONE, R.string.reset_counter)
    }

    override fun onContextItemSelected(item: MenuItem): Boolean {
        if (item.itemId != MENU_RESET) {
            return super.onContextItemSelected(item)
        }
        try {
            counter.reset()
            showCount(0)
        } catch (failure: IllegalStateException) {
            Log.e(LOG_TAG, "reset not saved: ${failure.message}")
        }
        return true
    }

    companion object {
        /** The SharedPreferences file of the counter. */
        const val PREFERENCES = "hellotext"

        /**
         * Opens the counter over the fixture's SharedPreferences file. The button and the debug-only receiver
         * (src/debug) both open it here, so they use the same store.
         */
        fun openCounter(context: Context): CounterStore =
            CounterStore(PreferencesKeyValueStore(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)))

        /** The logcat tag of the click lines. */
        const val LOG_TAG = "APKRUN-FIXTURE"

        private const val MENU_RESET = 1
    }
}
