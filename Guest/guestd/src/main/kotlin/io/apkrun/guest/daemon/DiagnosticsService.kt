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
    private val agentLogPaths: List<String> =
        listOf(
            "/data/local/tmp/apkrun/agent.log",
            "/data/local/tmp/apkrun/agent.log.1",
        ),
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
            DiagnosticsItem.DIAGNOSTICS_ITEM_GETPROP ->
                shellItem(item, maxBytes, "getprop.txt", "getprop") { output ->
                    DiagnosticsAllowlist.filterGetprop(output)
                }
            DiagnosticsItem.DIAGNOSTICS_ITEM_LOGCAT ->
                shellItem(
                    item,
                    maxBytes,
                    "logcat.txt",
                    "logcat",
                    "-d",
                    "-b",
                    "main,system,crash",
                    "-v",
                    "threadtime,uid,UTC,year",
                )
            DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_WINDOW ->
                shellItem(item, maxBytes, "dumpsys-window.txt", "dumpsys", "window")
            DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_DISPLAY ->
                shellItem(item, maxBytes, "dumpsys-display.txt", "dumpsys", "display")
            DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_INPUT ->
                shellItem(item, maxBytes, "dumpsys-input.txt", "dumpsys", "input")
            DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_ACTIVITY ->
                shellItem(item, maxBytes, "dumpsys-activity.txt", "dumpsys", "activity")
            DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_MEMINFO ->
                shellItem(item, maxBytes, "dumpsys-meminfo.txt", "dumpsys", "meminfo", "-c")
            DiagnosticsItem.DIAGNOSTICS_ITEM_DUMPSYS_SURFACEFLINGER ->
                shellItem(item, maxBytes, "dumpsys-surfaceflinger.txt", "dumpsys", "SurfaceFlinger")
            DiagnosticsItem.DIAGNOSTICS_ITEM_TOMBSTONE_LIST -> tombstones(item, maxBytes)
            DiagnosticsItem.DIAGNOSTICS_ITEM_AGENT_LOG -> agentLog(item, maxBytes)
            else ->
                DiagnosticsItemResult.newBuilder()
                    .setItem(item)
                    .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_UNSUPPORTED)
                    .build()
        }
    }

    /**
     * The `ls -l` of the tombstone directory, or the dropbox crash index when the directory cannot
     * be listed (a `shell` process often cannot read it). List only: names, times, sizes — never
     * tombstone bodies.
     */
    private fun tombstones(item: DiagnosticsItem, maxBytes: Long): DiagnosticsItemResult {
        val listing =
            try {
                shellRunner.run("ls", "-l", "/data/tombstones/")
            } catch (error: Exception) {
                ByteArray(0)
            }
        val text = String(listing, Charsets.UTF_8)
        val useful = text.lines().count { it.contains("tombstone_") } > 0
        if (useful) {
            return sendPayload(
                item,
                maxBytes,
                "tombstones.txt",
                text.toByteArray(Charsets.UTF_8),
            )
        }
        // Fallback: `dumpsys dropbox` index lines of crash/tombstone tags
        // carry "time tag (…)" — time, process, signal class.
        return shellItem(item, maxBytes, "tombstones.txt", "dumpsys", "dropbox") { output ->
            String(output, Charsets.UTF_8)
                .lineSequence()
                .filter { line ->
                    line.contains("crash") ||
                        line.contains("tombstone") ||
                        line.contains("anr") ||
                        line.contains("wtf")
                }
                .joinToString("\n")
                .toByteArray(Charsets.UTF_8)
        }
    }

    /** Concatenates the agent's ring-buffer log files. */
    private fun agentLog(item: DiagnosticsItem, maxBytes: Long): DiagnosticsItemResult {
        val output = ByteArrayOutputStream()
        var any = false
        for (path in agentLogPaths) {
            try {
                val file = java.io.File(path)
                if (file.isFile) {
                    file.inputStream().use { it.copyTo(output) }
                    any = true
                }
            } catch (error: Exception) {
                AgentLog.error("agent log read failed: $path", error)
            }
        }
        if (!any) {
            return DiagnosticsItemResult.newBuilder()
                .setItem(item)
                .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_FAILED)
                .build()
        }
        return sendPayload(item, maxBytes, "agent.log", output.toByteArray())
    }

    private fun shellItem(
        item: DiagnosticsItem,
        maxBytes: Long,
        fileName: String,
        vararg command: String,
        transform: (ByteArray) -> ByteArray = { it },
    ): DiagnosticsItemResult {
        val output: ByteArray =
            try {
                transform(shellRunner.run(*command))
            } catch (error: Exception) {
                AgentLog.error("diagnostics ${command.joinToString(" ")} failed", error)
                return DiagnosticsItemResult.newBuilder()
                    .setItem(item)
                    .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_FAILED)
                    .build()
            }
        return sendPayload(item, maxBytes, fileName, output)
    }

    private fun sendPayload(
        item: DiagnosticsItem,
        maxBytes: Long,
        fileName: String,
        output: ByteArray,
    ): DiagnosticsItemResult {
        val limit = if (maxBytes > 0) minOf(maxBytes, MAX_ITEM_BYTES) else MAX_ITEM_BYTES
        if (output.size > MAX_ITEM_BYTES) {
            return DiagnosticsItemResult.newBuilder()
                .setItem(item)
                .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_TOO_LARGE)
                .build()
        }
        val truncated = output.size > limit
        val payload = if (truncated) output.copyOf(limit.toInt()) else output
        val transferId =
            bulk.sendDiagnosticsItem(fileName, "text/plain", payload)
                ?: return DiagnosticsItemResult.newBuilder()
                    .setItem(item)
                    .setStatus(DiagnosticsItemStatus.DIAGNOSTICS_ITEM_STATUS_FAILED)
                    .build()
        return DiagnosticsItemResult.newBuilder()
            .setItem(item)
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
