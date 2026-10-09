package io.apkrun.guest.runtime

import android.util.Log
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile

/**
 * The agent log (guest-components.md §9). Each line goes to logcat under the tag `ApkRunGuest`, and
 * to the agent's ring-buffer file when [install] is called. The file is at most
 * [MAXIMUM_FILE_BYTES] per file with [FILE_COUNT] files. The log never carries clipboard,
 * notification, or typed text.
 */
object AgentLog {
    /** The logcat tag of every agent line (guest-components.md §9). */
    const val TAG = "ApkRunGuest"

    /** The size limit of one log file: 1 MiB. */
    const val MAXIMUM_FILE_BYTES = 1L * 1024 * 1024

    /** The number of log files in the ring buffer: 2, so the log keeps at most 2 MiB. */
    const val FILE_COUNT = 2

    @Volatile private var ring: RingFile? = null

    /** Starts writing the agent log to [file] and its rotated sibling. */
    fun install(file: File) {
        ring = RingFile(file)
    }

    fun info(message: String) = write(Log.INFO, message)

    fun warning(message: String) = write(Log.WARN, message)

    fun error(message: String, error: Throwable? = null) {
        write(Log.ERROR, if (error == null) message else "$message: ${error.javaClass.name}")
    }

    private fun write(level: Int, message: String) {
        try {
            Log.println(level, TAG, message)
        } catch (error: RuntimeException) {
            // The logcat path is absent under plain JVM tests. The file below still records the
            // line.
        }
        ring?.append("${level.toLevelName()} $message")
    }

    private fun Int.toLevelName(): String =
        when (this) {
            Log.ERROR -> "E"
            Log.WARN -> "W"
            else -> "I"
        }

    /** Two files, `agent.log` and `agent.log.1`. The newer one is always `agent.log`. */
    private class RingFile(private val current: File) {
        private val previous = File(current.path + ".1")
        private var size = if (current.exists()) current.length() else 0L

        @Synchronized
        fun append(line: String) {
            val bytes = (line + "\n").toByteArray(Charsets.UTF_8)
            try {
                if (size + bytes.size > MAXIMUM_FILE_BYTES) {
                    rotate()
                }
                RandomAccessFile(current, "rw").use { file ->
                    file.seek(file.length())
                    file.write(bytes)
                }
                size += bytes.size
            } catch (error: IOException) {
                // A full or read-only log directory must not stop the agent. The logcat line
                // remains.
            }
        }

        private fun rotate() {
            previous.delete()
            current.renameTo(previous)
            size = 0L
        }
    }
}
