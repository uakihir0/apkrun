package io.apkrun.guest.daemon

import io.apkrun.guest.protocol.v1.CollectDiagnostics
import io.apkrun.guest.protocol.v1.CollectDiagnosticsResult
import io.apkrun.guest.protocol.v1.DiagnosticsItem
import io.apkrun.guest.protocol.v1.DiagnosticsItemResult
import io.apkrun.guest.protocol.v1.DiagnosticsItemStatus
import io.apkrun.guest.runtime.AgentLog
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/**
 * CollectDiagnostics, operation 73 (guest-protocol.md §7.1, diagnostics.md §5–§6). Each item is
 * answered on its own: an item this build does not have is UNSUPPORTED and never fails the request,
 * and a payload longer than the request's `max_bytes` is truncated. The payload itself travels as a
 * [BulkKind.BULK_KIND_DIAGNOSTICS_ITEM] transfer on the bulk channel.
 */
class DiagnosticsService(
    private val bulk: BulkTransfers,
    private val shellRunner: ShellRunner = ProcessShellRunner(),
) {
    /** Runs one CollectDiagnostics request. */
    fun collect(request: CollectDiagnostics): CollectDiagnosticsResult {
        val result = CollectDiagnosticsResult.newBuilder()
        for (item in request.itemsList) {
            result.addItems(collectItem(item, request.maxBytes))
        }
        return result.build()
    }

    private fun collectItem(item: DiagnosticsItem, maxBytes: Long): DiagnosticsItemResult {
        return when (item) {
            DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO -> dumpsysMeminfo(maxBytes)
            else ->
                DiagnosticsItemResult.newBuilder()
                    .setItem(item)
                    .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_UNSUPPORTED)
                    .build()
        }
    }

    private fun dumpsysMeminfo(maxBytes: Long): DiagnosticsItemResult {
        val limit = if (maxBytes > 0) minOf(maxBytes, MAX_ITEM_BYTES) else MAX_ITEM_BYTES
        val output: ByteArray =
            try {
                shellRunner.run("dumpsys", "meminfo", "-c")
            } catch (error: Exception) {
                AgentLog.error("dumpsys meminfo -c failed", error)
                return DiagnosticsItemResult.newBuilder()
                    .setItem(DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO)
                    .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_FAILED)
                    .build()
            }
        if (output.size > MAX_ITEM_BYTES) {
            return DiagnosticsItemResult.newBuilder()
                .setItem(DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO)
                .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_TOO_LARGE)
                .build()
        }
        val truncated = output.size > limit
        val payload = if (truncated) output.copyOf(limit.toInt()) else output
        val transferId =
            bulk.sendDiagnosticsItem("dumpsys-meminfo.txt", "text/plain", payload)
                ?: return DiagnosticsItemResult.newBuilder()
                    .setItem(DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO)
                    .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_FAILED)
                    .build()
        return DiagnosticsItemResult.newBuilder()
            .setItem(DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO)
            .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_OK)
            .setTransferId(transferId)
            .setTruncated(truncated)
            .build()
    }

    /** Runs a shell command and returns its bounded stdout, for testability. */
    interface ShellRunner {
        /** Runs [command] and returns stdout, at most [MAX_ITEM_BYTES] + 1 bytes. */
        fun run(vararg command: String): ByteArray
    }

    /** Runs a real process under the shell uid's permissions. */
    class ProcessShellRunner : ShellRunner {
        override fun run(vararg command: String): ByteArray {
            val process = ProcessBuilder(*command).redirectErrorStream(true).start()
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            val reader = process.inputStream
            // The read loop must not block: a command that never closes its
            // pipe still has to hit the deadline, so bytes are only consumed
            // while `available()` says they exist.
            val deadlineNanos = System.nanoTime() + TimeUnit.SECONDS.toNanos(TIMEOUT_SECONDS)
            while (output.size() <= MAX_ITEM_BYTES_INT) {
                val available = reader.available()
                if (available > 0) {
                    val read = reader.read(buffer, 0, minOf(available, buffer.size))
                    if (read < 0) {
                        break
                    }
                    output.write(buffer, 0, read)
                } else if (!process.isAlive) {
                    // The dead process left no writer: drain what it wrote and
                    // stop at end of stream. A single-byte peek would drop it.
                    val read = reader.read(buffer)
                    if (read < 0) {
                        break
                    }
                    output.write(buffer, 0, read)
                } else if (System.nanoTime() > deadlineNanos) {
                    process.destroyForcibly()
                    throw IllegalStateException(
                        "the command did not finish within ${TIMEOUT_SECONDS}s"
                    )
                } else {
                    Thread.sleep(POLL_MILLIS)
                }
            }
            val remainingNanos = deadlineNanos - System.nanoTime()
            if (remainingNanos <= 0 || !process.waitFor(remainingNanos, TimeUnit.NANOSECONDS)) {
                process.destroyForcibly()
                throw IllegalStateException("the command did not finish within ${TIMEOUT_SECONDS}s")
            }
            return output.toByteArray()
        }
    }

    companion object {
        /** The per-item byte cap of diagnostics.md §6. */
        const val MAX_ITEM_BYTES = 16L * 1024 * 1024
        private const val MAX_ITEM_BYTES_INT = 16 * 1024 * 1024
        /** The per-call timeout of diagnostics.md §6. */
        const val TIMEOUT_SECONDS = 60L
        private const val POLL_MILLIS = 10L
    }
}
