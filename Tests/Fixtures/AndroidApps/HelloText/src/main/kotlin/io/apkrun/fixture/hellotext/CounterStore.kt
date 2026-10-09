package io.apkrun.fixture.hellotext

/**
 * The click counter of HelloText. The count lives in a [KeyValueStore], so the logic runs on the JVM and
 * the Android backing store is injected at run time.
 */
class CounterStore(private val backend: KeyValueStore) {
    /** The count that the backend holds, or 0 before the first click. */
    fun current(): Int = backend.getInt(KEY, 0)

    /**
     * Adds one click, stores the new count, and returns it. Throws [IllegalStateException] when the backend
     * does not save the count, so that a lost click is never shown as a stored one.
     */
    fun increment(): Int {
        val next = current() + 1
        save(next)
        return next
    }

    /** Sets the count back to 0. */
    fun reset() {
        save(0)
    }

    private fun save(value: Int) {
        check(backend.putInt(KEY, value)) { "the counter could not be saved" }
    }

    companion object {
        const val KEY = "click_count"
    }
}

/** The part of SharedPreferences that the counter uses. */
interface KeyValueStore {
    fun getInt(key: String, defaultValue: Int): Int

    /** Stores the value. Returns false when the store did not save it. */
    fun putInt(key: String, value: Int): Boolean
}
