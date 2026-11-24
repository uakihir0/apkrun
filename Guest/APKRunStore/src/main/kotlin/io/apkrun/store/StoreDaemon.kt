package io.apkrun.store

import android.content.Context
import android.net.LocalSocket
import android.os.Process
import io.apkrun.guest.protocol.SessionManager
import io.apkrun.guest.protocol.v1.ChannelKind
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.AgentSocketServer
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/** The abstract socket of the store control channel (guest-components.md §8.2). */
const val CONTROL_SOCKET = "apkrun-store-control"

/** The abstract socket of the store artifact channel. */
const val ARTIFACTS_SOCKET = "apkrun-store-artifacts"

/** The logcat tag of the Store Agent (guest-components.md §9). */
const val LOGCAT_TAG = "ApkRunStore"

/**
 * The Store Agent (guest-components.md §8.2): the two abstract sockets, the session bookkeeping,
 * the dispatcher, and the install/ownership/metadata services. It is built once by
 * [StoreAgentApplication]. [start] binds the sockets; a [io.apkrun.guest.runtime.SocketNameInUse]
 * from the control socket means another agent runs.
 *
 * Only the bridge's `system` uid and `shell` (developer mode) may connect on the custom image
 * (guest-components.md §10.1).
 */
class StoreDaemon(private val context: Context) {
    internal val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    internal val sessions = SessionManager({ android.os.SystemClock.elapsedRealtime() })
    internal val events = StoreEvents()
    internal val install =
        InstallService(context, events) { android.os.SystemClock.elapsedRealtime() }
    private val ownership = OwnershipService(context.packageManager)
    private val metadata = MetadataService(context.packageManager, context.packageName)
    private val rollback = RollbackService(context)
    private val constraints = ConstraintsService(context.packageManager.packageInstaller)
    internal val transfers = StoreTransfers()
    private val icons = IconService(AndroidIconRenderer(context), transfers)
    private val enforcement = OwnershipEnforcement(context.contentResolver)
    internal val dispatcher =
        StoreDispatcher(
            operations =
                DeviceStoreOperations(
                    install,
                    ownership,
                    metadata,
                    rollback,
                    constraints,
                    icons,
                ),
            uptimeMillis = { android.os.SystemClock.elapsedRealtime() },
        )

    private val allowedPeer: (Int) -> Boolean = { uid ->
        uid == Process.SYSTEM_UID ||
            uid == io.apkrun.guest.runtime.PeerCheck.SHELL_UID ||
            uid == io.apkrun.guest.runtime.PeerCheck.ROOT_UID
    }

    private val sockets =
        listOf(
            AgentSocketServer(
                CONTROL_SOCKET,
                onPeer = { socket, _ -> serve(socket, ChannelKind.CHANNEL_KIND_STORE_CONTROL) },
                allowedPeer = allowedPeer,
            ),
            AgentSocketServer(
                ARTIFACTS_SOCKET,
                onPeer = { socket, _ -> serve(socket, ChannelKind.CHANNEL_KIND_STORE_ARTIFACTS) },
                allowedPeer = allowedPeer,
            ),
        )

    /** Binds both sockets, installs the file log, then starts accepting. */
    fun start() {
        AgentLog.install(File(context.cacheDir, "store.log"), LOGCAT_TAG)
        sockets.forEach { it.bind() }
        install.start()
        sockets.forEach { it.start() }
        AgentLog.info("apkrun_store is serving the control and artifact sockets")
    }

    /** The ownership-enforcement flag reported in Hello (guest-components.md §8.2). */
    internal fun ownershipEnforcement(): Boolean = enforcement.updateOwnershipEnforcement()

    private fun serve(socket: LocalSocket, channel: ChannelKind) {
        scope.launch(Dispatchers.IO) { StoreConnection(socket, channel, this@StoreDaemon).run() }
    }
}
