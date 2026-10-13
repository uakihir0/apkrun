package io.apkrun.fixture.hellotext

import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** T0 checks for the diagnostic FIFO queue; every store write still uses its synchronous commit contract. */
class CounterOperationQueueTest {
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val queue = CounterOperationQueue(executor)

    @After
    fun stopWorker() {
        executor.shutdownNow()
    }

    @Test
    fun incrementResetAndReadRunInSubmissionOrder() {
        val backend = MemoryStore()
        val counter = CounterStore(backend)
        val first = queue.submit { counter.increment() }
        val second = queue.submit { counter.increment() }
        val reset = queue.submit {
            counter.reset()
            counter.current()
        }
        val read = queue.submit { counter.current() }

        assertEquals(1, first.get(5, TimeUnit.SECONDS))
        assertEquals(2, second.get(5, TimeUnit.SECONDS))
        assertEquals(0, reset.get(5, TimeUnit.SECONDS))
        assertEquals(0, read.get(5, TimeUnit.SECONDS))
    }

    @Test
    fun reopenedStoreSeesCountAfterQueuedCommitCompletes() {
        val backend = MemoryStore()

        assertEquals(1, queue.submit { CounterStore(backend).increment() }.get(5, TimeUnit.SECONDS))
        assertEquals(1, queue.submit { CounterStore(backend).current() }.get(5, TimeUnit.SECONDS))
    }

    @Test
    fun failedCommitCompletesExceptionallyAndDoesNotAdvanceCount() {
        val backend = MemoryStore().apply {
            values[CounterStore.KEY] = 4
            refuseWrites = true
        }
        val increment = queue.submit { CounterStore(backend).increment() }

        val failure = try {
            increment.get(5, TimeUnit.SECONDS)
            throw AssertionError("the failed commit completed successfully")
        } catch (expected: ExecutionException) {
            expected.cause
        }

        assertTrue(failure is IllegalStateException)
        assertEquals(4, queue.submit { CounterStore(backend).current() }.get(5, TimeUnit.SECONDS))
    }

    private class MemoryStore : KeyValueStore {
        val values = mutableMapOf<String, Int>()
        var refuseWrites = false

        override fun getInt(key: String, defaultValue: Int): Int = values[key] ?: defaultValue

        override fun putInt(key: String, value: Int): Boolean {
            if (refuseWrites) return false
            values[key] = value
            return true
        }
    }
}
