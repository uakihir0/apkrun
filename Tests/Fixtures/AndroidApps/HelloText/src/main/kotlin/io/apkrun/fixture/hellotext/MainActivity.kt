package io.apkrun.fixture.hellotext

import android.app.Activity
import android.content.Context
import android.content.Intent
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
 * The main Activity of HelloText. It shows a counter that persists across process restarts. Each
 * click logs `APKRUN-FIXTURE: click <n>`. A long press on the target text logs `APKRUN-FIXTURE:
 * contextmenu` and offers a reset. The field takes the typed text, and the Details button opens the
 * Details screen (#025). The screen logs `APKRUN-FIXTURE: screen <name>` when it resumes.
 */
class MainActivity : Activity() {
    private lateinit var counter: CounterStore
    private lateinit var counterText: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        counter = openActivityCounter(this)
        counterText = findViewById(R.id.counter_text)
        CounterOperationQueue.processWide
            .submit { counter.current() }
            .whenComplete { value, failure ->
                runOnUiThread {
                    if (failure == null) {
                        showCount(value)
                    } else {
                        Log.e(LOG_TAG, "counter read failed: ${failure.message}")
                    }
                }
            }
        findViewById<Button>(R.id.increment_button).setOnClickListener { click() }
        findViewById<Button>(R.id.details_button).setOnClickListener {
            startActivity(Intent(this, DetailsActivity::class.java))
        }
        findViewById<EditText>(R.id.input_text)
            .addTextChangedListener(
                object : TextWatcher {
                    override fun beforeTextChanged(
                        s: CharSequence?,
                        start: Int,
                        count: Int,
                        after: Int,
                    ) = Unit

                    override fun onTextChanged(
                        s: CharSequence?,
                        start: Int,
                        before: Int,
                        count: Int,
                    ) = Unit

                    override fun afterTextChanged(s: Editable?) {
                        FixtureState.fieldText = s?.toString().orEmpty()
                    }
                }
            )
        // Enter in the field is the editor action of the field (imeOptions actionDone). The line
        // names the action only.
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
        if (CounterTouchTrace.isRecording()) {
            CounterTouchTrace.recordClickCallback(SystemClock.elapsedRealtimeNanos())
        }
        if (CounterTouchTrace.executionMode() == CounterClickExecutionMode.SYNCHRONOUS) {
            try {
                val value = counter.increment()
                Log.i(LOG_TAG, "click $value")
                showCount(value)
            } catch (failure: IllegalStateException) {
                Log.e(LOG_TAG, "click not saved: ${failure.message}")
            }
            return
        }
        CounterOperationQueue.processWide
            .submit { counter.increment() }
            .whenComplete { value, failure ->
                runOnUiThread {
                    if (failure == null) {
                        Log.i(LOG_TAG, "click $value")
                        showCount(value)
                    } else {
                        Log.e(LOG_TAG, "click not saved: ${failure.message}")
                    }
                }
            }
    }

    private fun showCount(value: Int) {
        counterText.text = getString(R.string.counter_format, value)
    }

    /**
     * The Activity's store records the SharedPreferences commit duration only during an explicitly
     * started trace. The debug receiver continues to use [openCounter] without this
     * instrumentation.
     */
    private fun openActivityCounter(context: Context): CounterStore {
        val preferences =
            PreferencesKeyValueStore(
                context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            )
        val tracedStore =
            object : KeyValueStore {
                override fun getInt(key: String, defaultValue: Int): Int =
                    preferences.getInt(key, defaultValue)

                override fun putInt(key: String, value: Int): Boolean {
                    if (!CounterTouchTrace.isRecording()) {
                        return preferences.putInt(key, value)
                    }
                    val startedAtNanos = SystemClock.elapsedRealtimeNanos()
                    val saved = preferences.putInt(key, value)
                    val completedAtNanos = SystemClock.elapsedRealtimeNanos()
                    val observedValue = preferences.getInt(key, 0)
                    CounterTouchTrace.recordCounterWrite(
                        atNanos = completedAtNanos,
                        durationNanos = completedAtNanos - startedAtNanos,
                        requestedValue = value,
                        saved = saved,
                        observedValue = observedValue,
                    )
                    return saved
                }
            }
        return CounterStore(tracedStore)
    }

    override fun onCreateContextMenu(
        menu: ContextMenu,
        v: View,
        menuInfo: ContextMenu.ContextMenuInfo?,
    ) {
        super.onCreateContextMenu(menu, v, menuInfo)
        Log.i(LOG_TAG, "contextmenu")
        menu.add(Menu.NONE, MENU_RESET, Menu.NONE, R.string.reset_counter)
    }

    override fun onContextItemSelected(item: MenuItem): Boolean {
        if (item.itemId != MENU_RESET) {
            return super.onContextItemSelected(item)
        }
        CounterOperationQueue.processWide
            .submit {
                counter.reset()
                0
            }
            .whenComplete { value, failure ->
                runOnUiThread {
                    if (failure == null) {
                        showCount(value)
                    } else {
                        Log.e(LOG_TAG, "reset not saved: ${failure.message}")
                    }
                }
            }
        return true
    }

    companion object {
        /** The SharedPreferences file of the counter. */
        const val PREFERENCES = "hellotext"

        /**
         * Opens the counter over the fixture's SharedPreferences file. The button and the
         * debug-only receiver (src/debug) both open it here, so they use the same store.
         */
        fun openCounter(context: Context): CounterStore =
            CounterStore(
                PreferencesKeyValueStore(
                    context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                )
            )

        /** The logcat tag of the click lines. */
        const val LOG_TAG = "APKRUN-FIXTURE"

        private const val MENU_RESET = 1
    }
}
