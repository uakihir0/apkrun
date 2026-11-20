package io.apkrun.store

import android.content.Context
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.BeginInstallResult
import io.apkrun.guest.protocol.v1.BulkAck
import io.apkrun.guest.protocol.v1.BulkAckStatus
import io.apkrun.guest.protocol.v1.BulkFrame
import io.apkrun.guest.protocol.v1.BulkKind
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InstallFinished
import io.apkrun.guest.protocol.v1.InstallProgress
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.InstallStage
import io.apkrun.guest.protocol.v1.InstallStatus
import io.apkrun.guest.protocol.v1.UninstallResult
import io.apkrun.guest.protocol.v1.UninstallStatus
import io.apkrun.guest.runtime.AgentLog
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** The agent abandons an install session not committed within 10 minutes (§11.3). */
internal const val SESSION_TTL_MILLIS = 10L * 60 * 1000

/**
 * InstallService of the Store Agent (guest-components.md §8.2, guest-protocol.md §11.3). It owns
 * the PackageInstaller sessions: `BeginInstall` opens one, the artifact channel streams each APK
 * into it, and `CommitInstall` verifies the staged package with Android's own parser before
 * committing. `STATUS_PENDING_USER_ACTION` abandons the session and reports `USER_ACTION_REQUIRED`:
 * the agent never shows UI.
 */
class InstallService(
    private val context: Context,
    private val events: StoreEvents,
    private val now: () -> Long,
    private val backend: InstallBackend,
    private val spoolRoot: File = File(context.cacheDir, "install"),
) {
    internal constructor(
        context: Context,
        events: StoreEvents,
        now: () -> Long,
    ) : this(context, events, now, AndroidInstallBackend(context))

    private class Artifact(
        val name: String,
        val size: Long,
        val sha256: ByteArray,
        val spool: File,
    )

    private class Session(
        val installId: String,
        val handle: SessionHandle,
        val expectedPackage: String,
        val expectedVersionCode: Long,
        val expectedSigners: List<ByteArray>,
        val artifacts: Map<String, Artifact>,
        val createdAt: Long,
    ) {
        /** The artifact currently being streamed, or null. */
        var open: OpenArtifact? = null
        var committed = false
    }

    private class OpenArtifact(
        /** The bulk transfer that opened this artifact; later frames match by it. */
        val transferId: Long,
        val artifact: Artifact,
        val stream: java.io.OutputStream,
        val spoolStream: java.io.OutputStream,
        val digest: MessageDigest,
        var written: Long = 0,
    )

    private val sessions = ConcurrentHashMap<String, Session>()

    init {
        backend.onFinished = { androidSessionId, status, message ->
            sessionFinished(androidSessionId, status, message)
        }
    }

    /** Opens a new install session for [request] (§11.3 step 1). */
    fun beginInstall(request: InstallRequest): BeginInstallResult {
        if (request.allowDowngrade) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "allow_downgrade is always false in v1",
            )
        }
        if (
            request.enableRollback &&
                request.mode != io.apkrun.guest.protocol.v1.InstallMode.INSTALL_MODE_UPDATE
        ) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "enable_rollback needs the UPDATE mode",
            )
        }
        if (request.artifactsCount == 0) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "an install needs at least one artifact",
            )
        }
        val installId = UUID.randomUUID().toString()
        val spoolDir = File(spoolRoot, installId)
        spoolDir.mkdirs()
        val artifacts =
            request.artifactsList.associate { spec ->
                spec.name to
                    Artifact(
                        spec.name,
                        spec.size.toLong(),
                        spec.sha256.toByteArray(),
                        File(spoolDir, safeName(spec.name)),
                    )
            }
        val handle =
            try {
                backend.createSession(
                    SessionParameters(
                        packageName = request.expectedPackage,
                        requestUpdateOwnership = request.requestUpdateOwnership,
                        enableRollback = request.enableRollback,
                        installReason = request.installReason,
                        packageSource = request.packageSource,
                    )
                )
            } catch (error: Exception) {
                spoolDir.deleteRecursively()
                throw error
            }
        sessions[installId] =
            Session(
                installId = installId,
                handle = handle,
                expectedPackage = request.expectedPackage,
                expectedVersionCode = request.expectedVersionCode,
                expectedSigners = request.expectedSignerSha256List.map { it.toByteArray() },
                artifacts = artifacts,
                createdAt = now(),
            )
        progress(installId, InstallStage.INSTALL_STAGE_RECEIVING, 0f)
        return BeginInstallResult.newBuilder()
            .setInstallId(installId)
            .setAndroidSessionId(handle.androidSessionId)
            .build()
    }

    /**
     * One BulkFrame of the artifact channel (§11.3 step 2). [reply] sends the answer frame on the
     * same connection.
     */
    fun receive(frame: BulkFrame, reply: (BulkFrame) -> Unit) {
        when (frame.kindCase) {
            BulkFrame.KindCase.BEGIN -> receiveBegin(frame, reply)
            BulkFrame.KindCase.CHUNK -> receiveChunk(frame, reply)
            BulkFrame.KindCase.END -> receiveEnd(frame, reply)
            BulkFrame.KindCase.ABORT -> receiveAbort(frame)
            else ->
                reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_REJECTED, "frame kind"))
        }
    }

    private fun receiveBegin(frame: BulkFrame, reply: (BulkFrame) -> Unit) {
        val begin = frame.begin
        if (begin.kind != BulkKind.BULK_KIND_INSTALL_ARTIFACT) {
            reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_REJECTED, "bulk kind"))
            return
        }
        val session = sessions[begin.context]
        val artifact = session?.artifacts?.get(begin.name)
        if (session == null || artifact == null) {
            reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_REJECTED, "unknown install"))
            return
        }
        if (session.open != null) {
            reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_REJECTED, "artifact open"))
            return
        }
        if (begin.size != artifact.size) {
            reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_TOO_LARGE, "size"))
            return
        }
        session.open =
            OpenArtifact(
                artifact = artifact,
                stream = session.handle.openWrite(artifact.name, 0, artifact.size),
                spoolStream = artifact.spool.outputStream(),
                digest = MessageDigest.getInstance("SHA-256"),
            )
    }

    private fun receiveChunk(frame: BulkFrame, reply: (BulkFrame) -> Unit) {
        val session = sessionOf(frame) ?: return
        val open = session.open ?: return
        val bytes = frame.chunk.toByteArray()
        if (open.written + bytes.size > open.artifact.size) {
            abandonQuietly(session)
            reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_TOO_LARGE, "oversize"))
            return
        }
        try {
            open.stream.write(bytes)
            open.spoolStream.write(bytes)
            open.digest.update(bytes)
            open.written += bytes.size
        } catch (error: Exception) {
            AgentLog.error("an artifact write failed", error)
            abandonQuietly(session)
            reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_REJECTED, "write failed"))
        }
    }

    private fun receiveEnd(frame: BulkFrame, reply: (BulkFrame) -> Unit) {
        val session = sessionOf(frame) ?: return
        val open = session.open ?: return
        runCatching {
            open.stream.close()
            open.spoolStream.close()
        }
        session.open = null
        val digest = open.digest.digest()
        if (open.written != open.artifact.size || !digest.contentEquals(open.artifact.sha256)) {
            abandonQuietly(session)
            reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_HASH_MISMATCH, "sha256"))
            return
        }
        reply(ack(frame.transferId, BulkAckStatus.BULK_ACK_STATUS_OK, ""))
        progress(session.installId, InstallStage.INSTALL_STAGE_RECEIVING, fraction(session))
    }

    private fun receiveAbort(frame: BulkFrame) {
        // BulkAbort carries no context: close the open artifact of the session, if any.
        sessionOf(frame)?.let { session ->
            runCatching {
                session.open?.stream?.close()
                session.open?.spoolStream?.close()
            }
            session.open = null
        }
    }

    /** Verifies the staged artifacts and commits the session (§11.3 step 3). */
    fun commitInstall(installId: String) {
        val session =
            sessions[installId]
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "unknown install id",
                )
        if (session.open != null) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION,
                "an artifact transfer is still open",
            )
        }
        val missing =
            session.artifacts.values.filter { !it.spool.exists() || it.spool.length() != it.size }
        if (missing.isNotEmpty()) {
            abandonQuietly(session)
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION,
                "artifacts are missing: ${missing.joinToString(",") { it.name }}",
            )
        }
        verifyStaged(session)
        session.committed = true
        progress(installId, InstallStage.INSTALL_STAGE_COMMITTING, 1f)
        session.handle.commit()
    }

    /** Abandons the session of [installId] (§11.3). */
    fun abandonInstall(installId: String) {
        val session =
            sessions.remove(installId)
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "unknown install id",
                )
        runCatching { session.handle.abandon() }
        spool(session).deleteRecursively()
    }

    /** The control connection closed: every uncommitted session is abandoned (§11.3). */
    fun controlClosed() {
        sessions.values.filter { !it.committed }.forEach { abandonQuietly(it) }
    }

    /** Removes sessions older than the 10-minute TTL (§11.3). Called by the daemon's sweeper. */
    fun sweepExpired() {
        val cutoff = now() - SESSION_TTL_MILLIS
        sessions.values
            .filter { !it.committed && it.createdAt < cutoff }
            .forEach {
                AgentLog.warning("abandoning install ${it.installId}: not committed in 10 minutes")
                abandonQuietly(it)
            }
    }

    fun uninstall(packageName: String, keepData: Boolean): UninstallResult {
        val latch = java.util.concurrent.CountDownLatch(1)
        val outcome = java.util.concurrent.atomic.AtomicReference<UninstallOutcome?>()
        backend.uninstall(packageName, keepData) {
            outcome.set(it)
            latch.countDown()
        }
        latch.await(20, java.util.concurrent.TimeUnit.SECONDS)
        val result =
            outcome.get()
                ?: return UninstallResult.newBuilder()
                    .setStatus(UninstallStatus.UNINSTALL_STATUS_FAILURE)
                    .setMessage("the uninstall did not finish in time")
                    .build()
        return UninstallResult.newBuilder()
            .setStatus(
                if (result.success) UninstallStatus.UNINSTALL_STATUS_SUCCESS
                else UninstallStatus.UNINSTALL_STATUS_FAILURE
            )
            .setMessage(result.message)
            .build()
    }

    /** The PackageInstaller status of a committed session arrived (§11.3 step 4). */
    private fun sessionFinished(androidSessionId: Int, androidStatus: Int, message: String) {
        val session =
            sessions.values.find { it.handle.androidSessionId == androidSessionId } ?: return
        sessions.remove(session.installId)
        val status =
            when {
                androidStatus == android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    runCatching { session.handle.abandon() }
                    InstallStatus.INSTALL_STATUS_USER_ACTION_REQUIRED
                }
                androidStatus == android.content.pm.PackageInstaller.STATUS_SUCCESS ->
                    InstallStatus.INSTALL_STATUS_SUCCESS
                else -> InstallStatus.INSTALL_STATUS_FAILURE
            }
        spool(session).deleteRecursively()
        events.installFinished(
            InstallFinished.newBuilder()
                .setInstallId(session.installId)
                .setStatus(status)
                .setAndroidStatus(androidStatus)
                .setMessage(message)
                .setInstalledVersionCode(session.expectedVersionCode)
                .build()
        )
    }

    private fun verifyStaged(session: Session) {
        val base = session.artifacts["base"] ?: session.artifacts.values.first()
        val info =
            backend.stagedArchiveInfo(base.spool)
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                    "the staged package does not parse",
                )
        if (session.expectedPackage.isNotEmpty() && info.packageName != session.expectedPackage) {
            invalid(session, "the staged package is ${info.packageName}")
        }
        if (session.expectedVersionCode > 0 && info.versionCode != session.expectedVersionCode) {
            invalid(session, "the staged version is ${info.versionCode}")
        }
        if (session.expectedSigners.isNotEmpty()) {
            val staged = info.signerSha256.toSet()
            val expected = session.expectedSigners.toSet()
            if (staged != expected) {
                invalid(session, "the staged signer does not match")
            }
        }
    }

    private fun invalid(session: Session, message: String): Nothing {
        abandonQuietly(session)
        throw GuestFailure(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, message)
    }

    private fun sessionOf(frame: BulkFrame): Session? {
        // Chunk and end frames do not carry the context: the open artifact identifies the session.
        return sessions.values.firstOrNull { it.open != null }
    }

    private fun abandonQuietly(session: Session) {
        sessions.remove(session.installId)
        runCatching { session.handle.abandon() }
        spool(session).deleteRecursively()
    }

    private fun spool(session: Session): File = File(spoolRoot, session.installId)

    private fun fraction(session: Session): Float {
        val total = session.artifacts.values.sumOf { it.size }
        if (total <= 0) return 0f
        val done =
            session.artifacts.values.sumOf { if (it.spool.exists()) it.spool.length() else 0 }
        return (done.toFloat() / total.toFloat()).coerceIn(0f, 1f)
    }

    private fun progress(installId: String, stage: InstallStage, fraction: Float) {
        events.installProgress(
            InstallProgress.newBuilder()
                .setInstallId(installId)
                .setStage(stage)
                .setFraction(fraction)
                .build()
        )
    }

    private fun ack(transferId: Long, status: BulkAckStatus, reason: String): BulkFrame =
        BulkFrame.newBuilder()
            .setTransferId(transferId)
            .setAck(BulkAck.newBuilder().setStatus(status).build())
            .build()

    private fun safeName(name: String): String = name.replace(Regex("[^A-Za-z0-9._-]"), "_")

    internal fun start() {
        // The 10-minute abandon of guest-protocol.md §11.3.
        Thread(
                {
                    while (true) {
                        Thread.sleep(60_000)
                        runCatching { sweepExpired() }
                    }
                },
                "apkrun-store-expiry",
            )
            .apply {
                isDaemon = true
                start()
            }
    }
}
