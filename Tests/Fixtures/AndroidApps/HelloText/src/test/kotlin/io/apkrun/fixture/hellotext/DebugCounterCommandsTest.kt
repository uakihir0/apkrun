package io.apkrun.fixture.hellotext

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The debug-only commands on the JVM, over the same CounterStore as the button (IR-920, #016 T0). */
class DebugCounterCommandsTest {
    private class MemoryStore : KeyValueStore {
        val values = mutableMapOf<String, Int>()

        override fun getInt(key: String, defaultValue: Int): Int = values[key] ?: defaultValue

        override fun putInt(key: String, value: Int): Boolean {
            values[key] = value
            return true
        }
    }

    @Test
    fun incrementLogsTheCountItStores() {
        val backend = MemoryStore()
        val commands = DebugCounterCommands(CounterStore(backend))

        assertEquals("debug increment 1", commands.run(DebugCounterCommands.ACTION_INCREMENT))
        assertEquals("debug increment 2", commands.run(DebugCounterCommands.ACTION_INCREMENT))
        assertEquals(2, backend.values[CounterStore.KEY])
    }

    @Test
    fun readLogsTheStoredCountAndChangesNothing() {
        val backend = MemoryStore()
        backend.values[CounterStore.KEY] = 3
        val commands = DebugCounterCommands(CounterStore(backend))

        assertEquals("debug read 3", commands.run(DebugCounterCommands.ACTION_READ))
        assertEquals("debug read 3", commands.run(DebugCounterCommands.ACTION_READ))
    }

    @Test
    fun aNewCommandsOverTheSameStoreSeeTheIncrements() {
        // The receiver builds new commands over the same preferences on each broadcast.
        val backend = MemoryStore()
        repeat(3) { DebugCounterCommands(CounterStore(backend)).run(DebugCounterCommands.ACTION_INCREMENT) }

        assertEquals("debug read 3", DebugCounterCommands(CounterStore(backend)).run(DebugCounterCommands.ACTION_READ))
    }

    @Test
    fun aRefusedIncrementIsReportedAsNotSaved() {
        val refusing = object : KeyValueStore {
            override fun getInt(key: String, defaultValue: Int): Int = defaultValue

            override fun putInt(key: String, value: Int): Boolean = false
        }

        assertEquals(
            "debug increment not saved: the counter could not be saved",
            DebugCounterCommands(CounterStore(refusing)).run(DebugCounterCommands.ACTION_INCREMENT),
        )
    }

    @Test
    fun anUnknownActionIsIgnored() {
        val commands = DebugCounterCommands(CounterStore(MemoryStore()))

        assertNull(commands.run("io.apkrun.fixture.hellotext.debug.OTHER"))
        assertNull(commands.run(null))
    }
}
