package io.apkrun.fixture.helloprobe;

import android.app.Activity;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.Bundle;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.util.Log;

import java.io.IOException;

/** Attempts the product agent capabilities from an ordinary untrusted_app process (#36). */
public final class MainActivity extends Activity {
    private static final String TAG = "HelloProbe";

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Log.i(TAG, "probe-start");
        Log.i(TAG, "unix-control=connecting");
        probeUnixSocket("control", "apkrun-guestd-control");
        Log.i(TAG, "unix-input=connecting");
        probeUnixSocket("input", "apkrun-guestd-input");
        Log.i(TAG, "unix-bulk=connecting");
        probeUnixSocket("bulk", "apkrun-guestd-bulk");
        Log.i(TAG, "vsock=connecting");
        probeVsock();
        Log.i(TAG, "probe-complete");
    }

    private static void probeUnixSocket(String label, String name) {
        LocalSocket socket = new LocalSocket();
        try {
            socket.connect(new LocalSocketAddress(name, LocalSocketAddress.Namespace.ABSTRACT));
            Log.e(TAG, "unix-" + label + "=connected");
        } catch (IOException | SecurityException error) {
            Log.i(
                    TAG,
                    "unix-" + label + "=" + (isDenied(error) ? "denied" : "unexpected")
                            + " error=" + error.getClass().getSimpleName()
                            + ":" + error.getMessage());
        } finally {
            try {
                socket.close();
            } catch (IOException ignored) {
                // The socket may not have been created.
            }
        }
    }

    private static void probeVsock() {
        try {
            Os.close(Os.socket(OsConstants.AF_VSOCK, OsConstants.SOCK_STREAM, 0));
            Log.e(TAG, "vsock=allowed");
        } catch (ErrnoException | SecurityException error) {
            Log.i(TAG, "vsock=" + (isDenied(error) ? "denied" : "unexpected"));
        }
    }

    private static boolean isDenied(Throwable error) {
        for (Throwable current = error; current != null; current = current.getCause()) {
            if (current instanceof ErrnoException errno
                    && (errno.errno == OsConstants.EACCES || errno.errno == OsConstants.EPERM)) {
                return true;
            }
            String message = current.getMessage();
            if (current instanceof SecurityException
                    || (message != null
                            && (message.toLowerCase().contains("permission denied")
                                    || message.toLowerCase().contains("operation not permitted")))) {
                return true;
            }
        }
        return false;
    }
}
