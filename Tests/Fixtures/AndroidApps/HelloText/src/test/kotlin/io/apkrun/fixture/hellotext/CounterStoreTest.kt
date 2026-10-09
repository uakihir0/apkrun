package io.apkrun.fixture.hellotext

import org.junit.Assert.assertEquals
import org.junit.Test

/** The counter logic on the JVM, with an in-memory backend in place of SharedPreferences (#016 T0). */
class CounterStoreTest {
    private class MemoryStore : KeyValueStore {
        val values = mutableMapOf<String, Int>()

        override fun getInt(key: String, defaultValue: Int): Int = values[key] ?: defaultValue

        override fun putInt(key: String, value: Int) {
            values[key] = value
        }
    }

    @Test
    fun startsAtZero() {
        assertEquals(0, CounterStore(MemoryStore()).current())
    }

    @Test
    fun incrementCountsUpAndStoresEachValue() {
        val backend = MemoryStore()
        val counter = CounterStore(backend)

        assertEquals(1, counter.increment())
        assertEquals(2, counter.increment())
        assertEquals(2, backend.values[CounterStore.KEY])
    }

    @Test
    fun aNewStoreOnTheSameBackendSeesTheCount() {
        // A restarted process builds a new CounterStore over the same preferences.
        val backend = MemoryStore()
        CounterStore(backend).increment()
        CounterStore(backend).increment()

        assertEquals(2, CounterStore(backend).current())
    }

    @Test
    fun resetSetsTheCountBackToZero() {
        val counter = CounterStore(MemoryStore())
        counter.increment()
        counter.reset()

        assertEquals(0, counter.current())
        assertEquals(1, counter.increment())
    }
}
