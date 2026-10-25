package io.apkrun.store.store

import android.content.Context
import android.content.Intent
import android.net.LocalSocket
import android.os.Build
import android.os.SystemClock
import io.apkrun.guest.protocol.ProtocolVersion
import io.apkrun.guest.protocol.v1.AgentInfo
import io.apkrun.guest.protocol.v1.AgentKind
import io.apkrun.guest.protocol.v1.AgentMode
import io.apkrun.guest.protocol.v1.AndroidInfo
import io.apkrun.guest.protocol.v1.ChannelKind
import io.apkrun.guest.protocol.v1.Envelope
import io.apkrun.guest.protocol.v1.Hello
import io.apkrun.guest.runtime.AgentLog
import io.apkrun.guest.runtime.AgentSocketServer
import io.apkrun.guest.runtime.PeerPolicy
import io.apkrun.guest.runtime.SocketNameInUse
import io.apkrun.guest.runtime.SystemContext
import io.apkrun.store.BuildConfig
import java.io.Closeable
import java.io.File
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

const val STORE_CONTROL_SOCKET = "apkrun-store-control"
const val STORE_ARTIFACTS_SOCKET = "apkrun-store-artifacts"

/** Owns the Store Agent's sockets, control session, services, and event stream. */
class StoreDaemon private constructor(context: Context) : Closeable {
    private val applicationContext = context.applicationContext ?: context
    private val events = StoreEventBus()
    private val catalog = AndroidStorePackageCatalog(applicationContext.packageManager)
    private val archiveInspector =
        ArchiveInspector(AndroidArchiveReader(applicationContext.packageManager))
    private val installService =
        InstallService(applicationContext, archiveInspector, catalog, events)
    private val uninstallService = UninstallService(applicationContext)
    private val metadataService = MetadataService(catalog)
    private val transfers = ArtifactTransferService(applicationContext, installService)
    private val operations =
        AndroidStoreOperations(
            applicationContext,
            installService,
            uninstallService,
            metadataService,
            transfers,
        )
    private val dispatcher =
        StoreDispatcher(operations, uptimeMillis = { SystemClock.elapsedRealtime() })
    private val requestScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val monitor = PackageMonitor(applicationContext, catalog, events)
    private val executor = newDaemonExecutor("apkrun-store")
    private val expiryExecutor: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "apkrun-store-expiry").apply { isDaemon = true }
        }
    private val socketServers =
        listOf(
            AgentSocketServer(STORE_CONTROL_SOCKET, PeerPolicy.CUSTOM_PRODUCT) { socket, _ ->
                executor.execute { serveControl(socket) }
            },
            AgentSocketServer(STORE_ARTIFACTS_SOCKET, PeerPolicy.CUSTOM_PRODUCT) { socket, _ ->
                executor.execute { serveArtifacts(socket) }
            },
        )

    private var handshakingControl: LocalSocket? = null
    private var activeControl: ActiveControl? = null
    private val artifactSockets = linkedMapOf<LocalSocket, String>()
    private var started = false

    @Synchronized
    @Throws(SocketNameInUse::class)
    fun start() {
        check(!started) { "the Store Agent is already started" }
        try {
            installService.cleanupStaleVerificationFiles()
            transfers.cleanupStaleInspectionFiles()
            socketServers.forEach(AgentSocketServer::bind)
            monitor.start()
            socketServers.forEach(AgentSocketServer::start)
            expiryExecutor.scheduleAtFixedRate(
                {
                    installService.expirePendingSessions()
                    transfers.expireInspectionArtifacts()
                },
                1,
                1,
                TimeUnit.MINUTES,
            )
            started = true
            AgentLog.info("the Store Agent is serving control and artifact sockets")
        } catch (error: Exception) {
            socketServers.forEach { runCatching { it.close() } }
            monitor.close()
            throw error
        }
    }

    override fun close() {
        socketServers.forEach { runCatching { it.close() } }
        monitor.close()
        val sessionId =
            synchronized(this) {
                val old = activeControl
                activeControl = null
                handshakingControl = null
                artifactSockets.keys.toList().forEach { runCatching { it.close() } }
                artifactSockets.clear()
                old?.sessionId
            }
        sessionId?.let {
            installService.abandonControlSession(it)
            transfers.closeControlSession(it)
        }
        transfers.closeAll()
        expiryExecutor.shutdownNow()
        requestScope.cancel()
        executor.shutdownNow()
        if (current === this) current = null
    }

    suspend fun dispatch(
        requestId: Long,
        request: io.apkrun.guest.protocol.v1.Request,
        enabledCapabilities: Set<String>,
        sessionId: String,
    ) = dispatcher.dispatch(requestId, request, enabledCapabilities, sessionId)

    fun cancel(sessionId: String, targetId: Long) = dispatcher.cancel(sessionId, targetId)

    fun acceptArtifact(frame: io.apkrun.guest.protocol.v1.BulkFrame, sessionId: String) =
        transfers.accept(frame, sessionId)

    fun handleInstallStatus(installId: String, intent: Intent) =
        installService.handleInstallStatus(installId, intent)

    fun completeUninstall(operationId: String, status: Int, message: String) =
        uninstallService.complete(operationId, status, message)

    fun controlClaimed(socket: LocalSocket): Boolean =
        synchronized(this) {
            val existing = activeControl
            if (
                existing != null &&
                    SystemClock.elapsedRealtime() - existing.lastActivityMillis <
                        CONTROL_TAKEOVER_MILLIS
            ) {
                return@synchronized false
            }
            if (existing != null) {
                activeControl = null
                artifactSockets.keys.toList().forEach { runCatching { it.close() } }
                artifactSockets.clear()
                installService.abandonControlSession(existing.sessionId)
                transfers.closeControlSession(existing.sessionId)
                runCatching { existing.socket.close() }
            }
            if (handshakingControl != null) return@synchronized false
            handshakingControl = socket
            true
        }

    private fun activateControl(
        socket: LocalSocket,
        token: ByteArray,
        enabledCapabilities: Set<String>,
        writer: StoreFrameWriter,
    ): ActiveControl? =
        synchronized(this) {
            if (handshakingControl !== socket || token.size != SESSION_TOKEN_BYTES) {
                return@synchronized null
            }
            handshakingControl = null
            ActiveControl(
                    socket = socket,
                    token = token.copyOf(),
                    sessionId = UUID.randomUUID().toString(),
                    enabledCapabilities = enabledCapabilities,
                    writer = writer,
                    lastActivityMillis = SystemClock.elapsedRealtime(),
                )
                .also { activeControl = it }
        }

    fun admitArtifacts(socket: LocalSocket, token: ByteArray): String? =
        synchronized(this) {
            val control = activeControl ?: return@synchronized null
            if (!control.token.contentEquals(token)) return@synchronized null
            artifactSockets[socket] = control.sessionId
            control.sessionId
        }

    private fun recordControlActivity(socket: LocalSocket): ActiveControl? =
        synchronized(this) {
            val control = activeControl?.takeIf { it.socket === socket } ?: return@synchronized null
            control.lastActivityMillis = SystemClock.elapsedRealtime()
            control
        }

    fun closeArtifacts(socket: LocalSocket) {
        synchronized(this) { artifactSockets.remove(socket) }
    }

    fun closeControl(socket: LocalSocket) {
        val ended =
            synchronized(this) {
                if (handshakingControl === socket) handshakingControl = null
                val control = activeControl?.takeIf { it.socket === socket } ?: return
                activeControl = null
                val secondaries =
                    artifactSockets.filterValues { it == control.sessionId }.keys.toList()
                secondaries.forEach { artifactSockets.remove(it) }
                secondaries.forEach { runCatching { it.close() } }
                control
            }
        events.detach(ended.writer)
        installService.abandonControlSession(ended.sessionId)
        transfers.closeControlSession(ended.sessionId)
        AgentLog.info("the Store Agent control session ended")
    }

    private fun serveControl(socket: LocalSocket) {
        if (!controlClaimed(socket)) {
            socket.close()
            return
        }
        val writer = StoreFrameWriter(socket.outputStream, closeConnection = { socket.close() })
        try {
            val reader = StoreFrameReader(socket.inputStream)
            writer.send { it.setHello(hello(ChannelKind.CHANNEL_KIND_STORE_CONTROL)) }
            socket.soTimeout = HANDSHAKE_TIMEOUT_MILLIS
            val ackEnvelope = reader.next()
            socket.soTimeout = 0
            if (ackEnvelope.bodyCase != Envelope.BodyCase.HELLO_ACK) {
                AgentLog.warning("the Store Agent control handshake did not start with HelloAck")
                return
            }
            val negotiated =
                io.apkrun.guest.protocol.AgentHandshake.evaluate(
                    ackEnvelope.helloAck,
                    ProtocolVersion.HOST,
                    SUPPORTED_CAPABILITIES,
                )
            val active =
                activateControl(
                    socket,
                    negotiated.sessionToken,
                    negotiated.enabledCapabilities.toSet(),
                    writer,
                ) ?: return
            events.attach(writer, active.enabledCapabilities)
            controlLoop(socket, reader, writer, active)
        } catch (error: io.apkrun.guest.protocol.GuestProtocolFailure) {
            AgentLog.warning("closed a Store Agent control connection: ${error.message}")
        } catch (_: java.net.SocketTimeoutException) {
            AgentLog.warning("the Store Agent control handshake timed out")
        } catch (error: java.io.IOException) {
            AgentLog.info("the Store Agent control connection ended")
        } catch (error: Exception) {
            AgentLog.error("the Store Agent control connection failed", error)
        } finally {
            closeControl(socket)
            writer.close()
            runCatching { socket.close() }
        }
    }

    private fun controlLoop(
        socket: LocalSocket,
        reader: StoreFrameReader,
        writer: StoreFrameWriter,
        initial: ActiveControl,
    ) {
        var lastRequestId = 0L
        var control = initial
        val connectionJob = SupervisorJob(requestScope.coroutineContext[Job])
        val connectionScope = CoroutineScope(requestScope.coroutineContext + connectionJob)
        try {
            while (true) {
                val envelope = reader.next()
                control = recordControlActivity(socket) ?: return
                when (envelope.bodyCase) {
                    Envelope.BodyCase.REQUEST -> {
                        if (envelope.id <= lastRequestId) {
                            throw io.apkrun.guest.protocol.GuestProtocolFailure.MalformedFrame(
                                "a Store Agent request id did not increase"
                            )
                        }
                        lastRequestId = envelope.id
                        connectionScope.launch(start = CoroutineStart.UNDISPATCHED) {
                            try {
                                val response =
                                    dispatch(
                                        envelope.id,
                                        envelope.request,
                                        control.enabledCapabilities,
                                        control.sessionId,
                                    )
                                writer.send(replyTo = envelope.id) { it.setResponse(response) }
                            } catch (_: CancellationException) {
                                // The socket or daemon closed while this request was running.
                            } catch (error: java.io.IOException) {
                                AgentLog.info("the Store Agent control connection ended")
                            } catch (error: Exception) {
                                AgentLog.error("a Store Agent response could not be sent", error)
                            }
                        }
                    }
                    Envelope.BodyCase.CANCEL -> cancel(control.sessionId, envelope.cancel.targetId)
                    else ->
                        throw io.apkrun.guest.protocol.GuestProtocolFailure.MalformedFrame(
                            "the body is not allowed on the Store Agent control channel"
                        )
                }
            }
        } finally {
            connectionJob.cancel()
        }
    }

    private fun serveArtifacts(socket: LocalSocket) {
        val writer = StoreFrameWriter(socket.outputStream, closeConnection = { socket.close() })
        try {
            val reader = StoreFrameReader(socket.inputStream)
            writer.send { it.setHello(hello(ChannelKind.CHANNEL_KIND_STORE_ARTIFACTS)) }
            socket.soTimeout = HANDSHAKE_TIMEOUT_MILLIS
            val ackEnvelope = reader.next()
            socket.soTimeout = 0
            if (ackEnvelope.bodyCase != Envelope.BodyCase.HELLO_ACK) {
                AgentLog.warning("the Store Agent artifact handshake did not start with HelloAck")
                return
            }
            val negotiated =
                io.apkrun.guest.protocol.AgentHandshake.evaluate(
                    ackEnvelope.helloAck,
                    ProtocolVersion.HOST,
                    SUPPORTED_CAPABILITIES,
                )
            if (
                io.apkrun.guest.protocol.GuestCapability.BULK.wireName !in
                    negotiated.enabledCapabilities
            ) {
                AgentLog.warning("refused a Store Agent artifact connection without bulk.v1")
                return
            }
            val sessionId = admitArtifacts(socket, negotiated.sessionToken)
            if (sessionId == null) {
                AgentLog.warning("refused a Store Agent artifact connection with a stale token")
                return
            }
            artifactLoop(reader, writer, sessionId)
        } catch (error: io.apkrun.guest.protocol.GuestProtocolFailure) {
            AgentLog.warning("closed a Store Agent artifact connection: ${error.message}")
        } catch (_: java.net.SocketTimeoutException) {
            AgentLog.warning("the Store Agent artifact handshake timed out")
        } catch (error: java.io.IOException) {
            AgentLog.info("the Store Agent artifact connection ended")
        } catch (error: Exception) {
            AgentLog.error("the Store Agent artifact connection failed", error)
        } finally {
            closeArtifacts(socket)
            writer.close()
            runCatching { socket.close() }
        }
    }

    private fun artifactLoop(
        reader: StoreFrameReader,
        writer: StoreFrameWriter,
        sessionId: String,
    ) {
        while (true) {
            val envelope = reader.next()
            if (envelope.bodyCase != Envelope.BodyCase.BULK) {
                throw io.apkrun.guest.protocol.GuestProtocolFailure.MalformedFrame(
                    "the body is not allowed on the Store Agent artifact channel"
                )
            }
            val bulk = envelope.bulk
            val ack = acceptArtifact(bulk, sessionId) ?: continue
            writer.send {
                it.setBulk(
                    io.apkrun.guest.protocol.v1.BulkFrame.newBuilder()
                        .setTransferId(bulk.transferId)
                        .setAck(ack)
                )
            }
        }
    }

    private fun hello(channel: ChannelKind): Hello =
        Hello.newBuilder()
            .setProtocolVersion(
                io.apkrun.guest.protocol.v1.ProtocolVersion.newBuilder()
                    .setMajor(ProtocolVersion.HOST.major.toInt())
                    .setMinor(ProtocolVersion.HOST.minor.toInt())
            )
            .setAgent(
                AgentInfo.newBuilder()
                    .setKind(AgentKind.AGENT_KIND_STORE_AGENT)
                    .setVersionName(BuildConfig.VERSION_NAME)
                    .setVersionCode(BuildConfig.VERSION_CODE.toLong())
                    .setBuildId(Build.FINGERPRINT)
            )
            .setRuntimeImageVersion(
                io.apkrun.guest.runtime.HiddenApi.systemProperty("ro.boot.apkrun.image").orEmpty()
            )
            .setAndroid(
                AndroidInfo.newBuilder()
                    .setSdkInt(Build.VERSION.SDK_INT)
                    .setRelease(Build.VERSION.RELEASE.orEmpty())
                    .setBuildFingerprint(Build.FINGERPRINT.orEmpty())
                    .setBuildType(Build.TYPE.orEmpty())
            )
            .addAllCapabilities(SUPPORTED_CAPABILITIES.map { it.wireName })
            .setChannel(channel)
            .setMode(AgentMode.AGENT_MODE_PRIVILEGED_APP)
            .build()

    private data class ActiveControl(
        val socket: LocalSocket,
        val token: ByteArray,
        val sessionId: String,
        val enabledCapabilities: Set<String>,
        val writer: StoreFrameWriter,
        var lastActivityMillis: Long,
    )

    companion object {
        @Volatile
        var current: StoreDaemon? = null
            private set

        fun create(context: Context): StoreDaemon {
            val log = File(context.cacheDir, "store.log")
            log.parentFile?.mkdirs()
            AgentLog.install(log, tag = STORE_AGENT_LOG_TAG)
            SystemContext.install(context)
            return StoreDaemon(context).also { current = it }
        }

        private val SUPPORTED_CAPABILITIES =
            setOf(
                io.apkrun.guest.protocol.GuestCapability.CORE,
                io.apkrun.guest.protocol.GuestCapability.BULK,
                io.apkrun.guest.protocol.GuestCapability.STORE_INSTALL,
                io.apkrun.guest.protocol.GuestCapability.STORE_METADATA,
            )
        private const val HANDSHAKE_TIMEOUT_MILLIS = 5_000
        private const val SESSION_TOKEN_BYTES = 16
        private const val CONTROL_TAKEOVER_MILLIS = 15_000
        private const val STORE_AGENT_LOG_TAG = "ApkRunStore"

        private fun newDaemonExecutor(name: String): ExecutorService =
            Executors.newCachedThreadPool { runnable ->
                Thread(runnable, "$name-connection").apply { isDaemon = true }
            }
    }
}
