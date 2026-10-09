package io.apkrun.guest.runtime

import android.net.LocalServerSocket
import android.net.LocalSocket
import java.io.IOException

/**
 * The abstract socket name is already bound: another agent runs, so this one exits with status 3.
 */
class SocketNameInUse(val name: String) : IOException("the socket $name is already bound")

/**
 * One abstract socket of the agent (guest-components.md §3.2, §6.1). The socket accepts connections
 * only from the peers of [PeerCheck], and each accepted connection goes to [onPeer] with the peer's
 * uid.
 */
class AgentSocketServer(
    /** The abstract socket name, such as `apkrun-guestd-control`. It is shown as `@name`. */
    val name: String,
    private val onPeer: (LocalSocket, Int) -> Unit,
) {
    private var server: LocalServerSocket? = null

    /**
     * Binds the socket. Throws [SocketNameInUse] when the name is taken, which is the
     * single-instance rule of guest-components.md §3.2.
     */
    fun bind() {
        server =
            try {
                LocalServerSocket(name)
            } catch (error: IOException) {
                val message = error.message.orEmpty()
                if (message.contains("EADDRINUSE") || message.contains("Address already in use")) {
                    throw SocketNameInUse(name)
                }
                throw error
            }
    }

    /** Accepts connections on a daemon thread until [close]. [bind] must have succeeded. */
    fun start() {
        val listening = checkNotNull(server) { "the socket $name is not bound" }
        Thread({ acceptLoop(listening) }, "apkrun-accept-$name").apply {
            isDaemon = true
            start()
        }
    }

    /** Stops accepting connections. */
    fun close() {
        server?.close()
    }

    private fun acceptLoop(listening: LocalServerSocket) {
        while (true) {
            val socket =
                try {
                    listening.accept()
                } catch (error: IOException) {
                    return
                }
            val uid =
                try {
                    socket.peerCredentials.uid
                } catch (error: IOException) {
                    socket.close()
                    continue
                }
            if (!PeerCheck.isAllowed(uid)) {
                AgentLog.warning("refused a connection to @$name from uid $uid")
                socket.close()
                continue
            }
            onPeer(socket, uid)
        }
    }
}
