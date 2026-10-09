package io.apkrun.fixture.hellotext

/**
 * The click counter of HelloText. The count lives in a [KeyValueStore], so the logic runs on the JVM and
 * the Android backing store is injected at run time.
 */
class CounterStore(private val backend: KeyValueStore) {
    /** The count that the backend holds, or 0 before the first click. */
    fun current(): Int = backend.getInt(KEY, 0)

    /** Adds one click, stores the new count, and returns it. */
    fun increment(): Int {
        val next = current() + 1
        backend.putInt(KEY, next)
        return next
    }

    /** Sets the count back to 0. */
    fun reset() {
        backend.putInt(KEY, 0)
    }

    companion object {
        const val KEY = "click_count"
    }
}

/** The part of SharedPreferences that the counter uses. */
interface KeyValueStore {
    fun getInt(key: String, defaultValue: Int): Int

    fun putInt(key: String, value: Int)
}
