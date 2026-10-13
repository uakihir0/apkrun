package io.apkrun.fixture.hellotext

import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * Serializes HelloText counter work on one FIFO worker for an input-loss diagnostic experiment.
 *
 * Callers publish results only after the synchronous preference commit has returned. This moves commit latency off
 * the UI thread, but an abrupt process kill before a queued operation finishes can lose an unacknowledged click.
 * This is an experiment, not a production durability fix.
 */
class CounterOperationQueue(private val executor: Executor) {
    /** Runs [operation] after prior submissions and completes exceptionally when it fails. */
    fun <T> submit(operation: () -> T): CompletableFuture<T> {
        val result = CompletableFuture<T>()
        try {
            executor.execute {
                try {
                    result.complete(operation())
                } catch (failure: Throwable) {
                    result.completeExceptionally(failure)
                }
            }
        } catch (failure: Throwable) {
            result.completeExceptionally(failure)
        }
        return result
    }

    companion object {
        /** Shared by the Activity and debug receiver so their reads and writes cannot overtake each other. */
        val processWide = CounterOperationQueue(
            Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "HelloText-counter").apply { isDaemon = true }
            }
        )
    }
}
