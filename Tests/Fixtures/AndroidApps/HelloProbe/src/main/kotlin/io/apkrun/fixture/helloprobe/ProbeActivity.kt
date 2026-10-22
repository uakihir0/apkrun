package io.apkrun.fixture.helloprobe

import android.app.Activity
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.Bundle
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import android.widget.TextView
import java.io.File
import java.io.IOException

/**
 * An ordinary untrusted app that attempts the Guest Agent's abstract sockets and AF_VSOCK.
 *
 * The host integration test reads the stable `probe <target> <result>` log markers and checks
 * the corresponding SELinux denials from the kernel log.
 */
class ProbeActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val status = TextView(this).apply { text = "Probing APKRun guest endpoints…" }
        setContentView(status)
        Thread {
            val results = runProbes()
            runOnUiThread { status.text = results.joinToString("\n") }
        }.start()
    }

    private fun runProbes(): List<String> {
        val results = mutableListOf<String>()
        val context = runCatching { File("/proc/self/attr/current").readText().trim() }
            .getOrDefault("unavailable")
        report("context", context, results)

        for (name in agentSockets) {
            val result = try {
                LocalSocket().use { socket ->
                    socket.connect(
                        LocalSocketAddress(name, LocalSocketAddress.Namespace.ABSTRACT)
                    )
                }
                "allowed"
            } catch (error: IOException) {
                errnoResult(error)
            }
            report("socket:$name", result, results)
        }

        val vsockResult = try {
            val descriptor = Os.socket(OsConstants.AF_VSOCK, OsConstants.SOCK_STREAM, 0)
            runCatching { Os.close(descriptor) }
            "allowed"
        } catch (error: ErrnoException) {
            permissionResult(error.errno)
        } catch (error: IOException) {
            errnoResult(error)
        }
        report("vsock", vsockResult, results)
        report("complete", "ok", results)
        return results
    }

    private fun report(target: String, result: String, output: MutableList<String>) {
        val marker = "probe $target $result"
        Log.i(TAG, marker)
        output += marker
    }

    private fun errnoResult(error: Throwable): String {
        var cause: Throwable? = error
        while (cause != null) {
            if (cause is ErrnoException) {
                return permissionResult(cause.errno)
            }
            cause = cause.cause
        }
        return "error:${error.javaClass.simpleName}"
    }

    private fun permissionResult(errno: Int): String =
        if (errno == OsConstants.EACCES || errno == OsConstants.EPERM) {
            "denied errno=$errno"
        } else {
            "error errno=$errno"
        }

    private companion object {
        const val TAG = "APKRUN-FIXTURE"
        val agentSockets = listOf(
            "apkrun-guestd-control",
            "apkrun-guestd-input",
            "apkrun-guestd-bulk",
        )
    }
}
