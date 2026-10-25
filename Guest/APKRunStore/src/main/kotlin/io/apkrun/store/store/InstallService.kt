package io.apkrun.store.store

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.SystemClock
import io.apkrun.guest.protocol.v1.AbandonInstall
import io.apkrun.guest.protocol.v1.ArtifactSpec
import io.apkrun.guest.protocol.v1.BeginInstallResult
import io.apkrun.guest.protocol.v1.CommitInstall
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InstallFinished
import io.apkrun.guest.protocol.v1.InstallProgress
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.InstallStage
import io.apkrun.guest.protocol.v1.InstallStatus
import io.apkrun.guest.runtime.AgentLog
import java.io.File
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Emits the Store Agent's negotiated events on its control connection. */
fun interface StoreEventSink {
    fun publish(capability: String, build: (Event.Builder) -> Unit)
}

/** A PackageInstaller-backed install session and the artifact set it is authorized to receive. */
class InstallService
internal constructor(
    private val inspector: ArchiveInspector,
    private val catalog: StorePackageCatalog,
    private val events: StoreEventSink,
    private val installer: StorePackageInstaller,
    private val verificationRoot: File,
    private val clockMillis: () -> Long = SystemClock::elapsedRealtime,
) {
    constructor(
        context: Context,
        inspector: ArchiveInspector,
        catalog: StorePackageCatalog,
        events: StoreEventSink,
        clockMillis: () -> Long = SystemClock::elapsedRealtime,
    ) : this(
        inspector = inspector,
        catalog = catalog,
        events = events,
        installer = AndroidStorePackageInstaller(context),
        verificationRoot = File(context.cacheDir, "apkrun-store/verify"),
        clockMillis = clockMillis,
    )

    private val pending = ConcurrentHashMap<String, PendingInstall>()
    private val installsByAndroidSession = ConcurrentHashMap<Int, String>()

    fun beginInstall(
        request: InstallRequest,
        enabledCapabilities: Set<String>,
        controlSessionId: String,
    ): BeginInstallResult {
        // Update ownership and rollback are intentionally not advertised until their follow-up
        // tasks. Requests that claim those capabilities cannot silently receive a partial install.
        if (request.requestUpdateOwnership || request.enableRollback) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED,
                "the requested install option is not implemented by this Store Agent",
            )
        }
        val androidSessionId =
            try {
                installer.createSession(request)
            } catch (error: IOException) {
                throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE,
                    "Android could not create an install session",
                    mapOf("exception" to error.javaClass.name),
                )
            }
        val session =
            try {
                installer.openSession(androidSessionId)
            } catch (error: IOException) {
                installer.abandonSession(androidSessionId)
                throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE,
                    "Android could not open the install session",
                    mapOf("exception" to error.javaClass.name),
                )
            }
        val installId = UUID.randomUUID().toString()
        val record =
            PendingInstall(
                installId = installId,
                androidSessionId = androidSessionId,
                controlSessionId = controlSessionId,
                request = request,
                session = session,
                createdAtMillis = clockMillis(),
            )
        if (pending.putIfAbsent(installId, record) != null) {
            session.close()
            installer.abandonSession(androidSessionId)
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INTERNAL,
                "the Store Agent could not allocate an install identifier",
            )
        }
        installsByAndroidSession[androidSessionId] = installId
        publishProgress(record, InstallStage.INSTALL_STAGE_RECEIVING, 0f)
        return BeginInstallResult.newBuilder()
            .setInstallId(installId)
            .setAndroidSessionId(androidSessionId)
            .build()
    }

    fun openArtifact(
        controlSessionId: String,
        installId: String,
        name: String,
        size: Long,
        declaredSha256: ByteArray?,
    ): InstallArtifactWriter {
        val record = requireOwnedInstall(installId, controlSessionId)
        val spec =
            record.artifacts[name]
                ?: throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                    "the artifact was not declared by BeginInstall",
                )
        val expectedSha256 = spec.sha256.toByteArray()
        if (
            size != spec.size ||
                (declaredSha256 != null && !declaredSha256.contentEquals(expectedSha256))
        ) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the streamed artifact does not match its declared size and digest",
            )
        }
        synchronized(record) {
            if (record.committed || record.abandoned) {
                throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION,
                    "the install session no longer accepts artifacts",
                )
            }
            if (name in record.receiving || name in record.received) {
                throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_ALREADY_EXISTS,
                    "the artifact was already received",
                )
            }
            record.receiving += name
        }
        val installDirectory = File(verificationRoot, installId)
        val staged = File(installDirectory, name)
        var sessionOutput: OutputStream? = null
        var stagedOutput: OutputStream? = null
        val output: OutputStream
        try {
            if (!installDirectory.exists() && !installDirectory.mkdirs()) {
                throw IOException("the install verification directory could not be created")
            }
            val openedSessionOutput = record.session.openWrite(name, size)
            sessionOutput = openedSessionOutput
            val openedStagedOutput = staged.outputStream()
            stagedOutput = openedStagedOutput
            output = InstallArtifactOutputStream(openedSessionOutput, openedStagedOutput)
        } catch (error: IOException) {
            runCatching { stagedOutput?.close() }
            runCatching { sessionOutput?.close() }
            staged.delete()
            synchronized(record) { record.receiving -= name }
            abandonRecord(record)
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE,
                "the Store Agent could not stage an install artifact",
                mapOf("exception" to error.javaClass.name),
            )
        }
        return InstallArtifactWriter(output) { success, digest, bytesWritten ->
            try {
                if (success && bytesWritten == size && digest.contentEquals(expectedSha256)) {
                    output.flush()
                    record.session.fsync(checkNotNull(sessionOutput))
                    output.close()
                    synchronized(record) {
                        record.received[name] = digest.copyOf()
                        record.receiving -= name
                    }
                    publishProgress(
                        record,
                        InstallStage.INSTALL_STAGE_RECEIVING,
                        receivedFraction(record),
                    )
                } else {
                    runCatching { output.close() }
                    abandonRecord(record)
                }
            } catch (error: Exception) {
                runCatching { output.close() }
                abandonRecord(record)
                throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE,
                    "the Store Agent could not persist an install artifact",
                    mapOf("exception" to error.javaClass.name),
                )
            } finally {
                if (!success || bytesWritten != size || !digest.contentEquals(expectedSha256)) {
                    staged.delete()
                }
            }
        }
    }

    fun commitInstall(request: CommitInstall, controlSessionId: String) {
        val record = requireOwnedInstall(request.installId, controlSessionId)
        synchronized(record) {
            if (record.committed || record.abandoned) {
                throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION,
                    "the install session is no longer pending",
                )
            }
            if (record.received.keys != record.artifacts.keys || record.receiving.isNotEmpty()) {
                throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION,
                    "the install session has missing or incomplete artifacts",
                )
            }
            record.committed = true
        }
        publishProgress(record, InstallStage.INSTALL_STAGE_VERIFYING, 1f)
        val verificationDirectory = File(verificationRoot, record.installId)
        val files = mutableListOf<File>()
        val inspected =
            try {
                record.artifacts.keys.forEach { name ->
                    val staged = File(verificationDirectory, name)
                    files += staged
                }
                inspector.inspect(files)
            } catch (error: Exception) {
                AgentLog.error("could not verify the staged install APK set", error)
                finishInvalid(record, "Android could not verify the staged APK set")
                return
            } finally {
                files.forEach(File::delete)
                verificationDirectory.deleteRecursively()
            }
        if (
            !matchesExpected(
                record,
                inspected.getPackage(),
                inspected.versionCode,
                inspected.signerSha256List.map { it.toByteArray() },
            )
        ) {
            finishInvalid(record, "the staged APK does not match the verified package metadata")
            return
        }
        publishProgress(record, InstallStage.INSTALL_STAGE_COMMITTING, 1f)
        try {
            record.session.commit(record.installId)
            record.session.close()
        } catch (error: SecurityException) {
            abandonRecord(record)
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_PERMISSION_DENIED,
                "Android refused to commit the install session",
            )
        } catch (error: Exception) {
            abandonRecord(record)
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_UNAVAILABLE,
                "Android could not commit the install session",
                mapOf("exception" to error.javaClass.name),
            )
        }
    }

    fun abandonInstall(request: AbandonInstall, controlSessionId: String) {
        val record = requireOwnedInstall(request.installId, controlSessionId)
        abandonRecord(record)
    }

    fun abandonControlSession(controlSessionId: String) {
        pending.values
            .filter { it.controlSessionId == controlSessionId && !it.committed }
            .forEach(::abandonRecord)
    }

    /** Abandons any uncommitted PackageInstaller sessions that have aged out. */
    fun expirePendingSessions() {
        val now = clockMillis()
        pending.values
            .filter {
                !it.committed && now - it.createdAtMillis >= SESSION_EXPIRATION_MILLIS
            }
            .forEach(::abandonRecord)
    }

    fun handleInstallStatus(installId: String, statusIntent: Intent) {
        val androidStatus =
            statusIntent.getIntExtra(
                PackageInstaller.EXTRA_STATUS,
                PackageInstaller.STATUS_FAILURE,
            )
        handleInstallStatus(
            installId = installId,
            androidStatus = androidStatus,
            legacyStatus = statusIntent.getIntExtra(LEGACY_STATUS_EXTRA, 0),
            message = statusIntent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty(),
        )
    }

    internal fun handleInstallStatus(
        installId: String,
        androidStatus: Int,
        legacyStatus: Int = 0,
        message: String = "",
    ) {
        val record = pending[installId] ?: return
        if (androidStatus == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            runCatching { installer.abandonSession(record.androidSessionId) }
            emitFinished(
                record,
                InstallStatus.INSTALL_STATUS_USER_ACTION_REQUIRED,
                androidStatus,
                legacyStatus,
                message,
                0,
            )
            return
        }
        val versionCode =
            if (androidStatus == PackageInstaller.STATUS_SUCCESS) {
                catalog.find(record.request.expectedPackage)?.versionCode ?: 0L
            } else {
                0L
            }
        emitFinished(
            record,
            installStatusFromAndroid(androidStatus),
            androidStatus,
            legacyStatus,
            message,
            versionCode,
        )
    }

    private fun matchesExpected(
        record: PendingInstall,
        packageName: String,
        versionCode: Long,
        signerDigests: List<ByteArray>,
    ): Boolean {
        if (packageName != record.request.expectedPackage) return false
        if (
            record.request.expectedVersionCode != 0L &&
                versionCode != record.request.expectedVersionCode
        ) {
            return false
        }
        val expected =
            record.request.expectedSignerSha256List
                .map { it.toByteArray() }
                .sortedWith(DIGEST_ORDER)
        val actual = signerDigests.sortedWith(DIGEST_ORDER)
        if (actual.isEmpty()) return false
        if (expected.isEmpty()) return true
        return expected.size == actual.size &&
            expected.zip(actual).all { (left, right) -> left.contentEquals(right) }
    }

    private fun finishInvalid(record: PendingInstall, message: String) {
        synchronized(record) { record.abandoned = true }
        runCatching { record.session.abandon() }
        record.session.close()
        pending.remove(record.installId)
        installsByAndroidSession.remove(record.androidSessionId)
        publishFinished(
            record,
            InstallStatus.INSTALL_STATUS_INVALID,
            PackageInstaller.STATUS_FAILURE,
            LEGACY_INVALID_APK_STATUS,
            message,
            0,
        )
    }

    private fun emitFinished(
        record: PendingInstall,
        status: InstallStatus,
        androidStatus: Int,
        legacyStatus: Int,
        message: String,
        installedVersionCode: Long,
    ) {
        publishFinished(
            record,
            status,
            androidStatus,
            legacyStatus,
            message,
            installedVersionCode,
        )
        pending.remove(record.installId)
        installsByAndroidSession.remove(record.androidSessionId)
    }

    private fun publishFinished(
        record: PendingInstall,
        status: InstallStatus,
        androidStatus: Int,
        legacyStatus: Int,
        message: String,
        installedVersionCode: Long,
    ) {
        events.publish(StoreDispatcher.STORE_INSTALL_CAPABILITY) {
            it.setInstallFinished(
                InstallFinished.newBuilder()
                    .setInstallId(record.installId)
                    .setStatus(status)
                    .setAndroidStatus(androidStatus)
                    .setLegacyStatus(legacyInstallStatusName(legacyStatus))
                    .setMessage(message.take(MAXIMUM_STATUS_MESSAGE_LENGTH))
                    .setInstalledVersionCode(installedVersionCode)
            )
        }
    }

    private fun publishProgress(record: PendingInstall, stage: InstallStage, fraction: Float) {
        events.publish(StoreDispatcher.STORE_INSTALL_CAPABILITY) {
            it.setInstallProgress(
                InstallProgress.newBuilder()
                    .setInstallId(record.installId)
                    .setStage(stage)
                    .setFraction(fraction.coerceIn(0f, 1f))
            )
        }
    }

    private fun receivedFraction(record: PendingInstall): Float {
        val total = record.artifacts.values.sumOf(ArtifactSpec::getSize)
        if (total <= 0L) return 0f
        val received = record.received.keys.sumOf { name -> record.artifacts.getValue(name).size }
        return received.toFloat() / total
    }

    private fun requireOwnedInstall(installId: String, controlSessionId: String): PendingInstall =
        pending[installId]?.takeIf { it.controlSessionId == controlSessionId }
            ?: throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the install session does not exist",
            )

    private fun abandonRecord(record: PendingInstall) {
        synchronized(record) {
            if (record.abandoned) return
            record.abandoned = true
        }
        runCatching { record.session.abandon() }
        runCatching { record.session.close() }
        File(verificationRoot, record.installId).deleteRecursively()
        record.receiving.clear()
        pending.remove(record.installId)
        installsByAndroidSession.remove(record.androidSessionId)
        AgentLog.info("abandoned pending install session ${record.androidSessionId}")
    }

    /** Removes app-private copies left behind by a Store Agent process restart. */
    fun cleanupStaleVerificationFiles() {
        verificationRoot.listFiles()?.forEach { entry ->
            if (!entry.deleteRecursively()) {
                AgentLog.warning("could not remove a stale install verification directory")
            }
        }
    }

    private data class PendingInstall(
        val installId: String,
        val androidSessionId: Int,
        val controlSessionId: String,
        val request: InstallRequest,
        val session: StoreInstallSession,
        val createdAtMillis: Long,
        val artifacts: Map<String, ArtifactSpec> =
            request.artifactsList.associateBy(ArtifactSpec::getName),
        val received: MutableMap<String, ByteArray> = mutableMapOf(),
        val receiving: MutableSet<String> = mutableSetOf(),
        var committed: Boolean = false,
        var abandoned: Boolean = false,
    )

    companion object {
        const val SESSION_EXPIRATION_MILLIS = 10 * 60 * 1_000L
        private const val MAXIMUM_STATUS_MESSAGE_LENGTH = 1_024
        private const val LEGACY_INVALID_APK_STATUS = -2
        private const val LEGACY_STATUS_EXTRA = "android.content.pm.extra.LEGACY_STATUS"
        private val DIGEST_ORDER =
            Comparator<ByteArray> { left, right ->
                for (index in 0 until minOf(left.size, right.size)) {
                    val result =
                        (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
                    if (result != 0) return@Comparator result
                }
                left.size.compareTo(right.size)
            }
    }
}

internal fun installStatusFromAndroid(status: Int): InstallStatus =
    when (status) {
        PackageInstaller.STATUS_SUCCESS -> InstallStatus.INSTALL_STATUS_SUCCESS
        PackageInstaller.STATUS_FAILURE_ABORTED -> InstallStatus.INSTALL_STATUS_ABORTED
        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> InstallStatus.INSTALL_STATUS_INCOMPATIBLE
        PackageInstaller.STATUS_FAILURE_CONFLICT -> InstallStatus.INSTALL_STATUS_CONFLICT
        PackageInstaller.STATUS_FAILURE_STORAGE -> InstallStatus.INSTALL_STATUS_STORAGE
        PackageInstaller.STATUS_FAILURE_INVALID -> InstallStatus.INSTALL_STATUS_INVALID
        PackageInstaller.STATUS_FAILURE_BLOCKED -> InstallStatus.INSTALL_STATUS_BLOCKED
        else -> InstallStatus.INSTALL_STATUS_FAILURE
    }

internal fun legacyInstallStatusName(status: Int): String =
    when (status) {
        -1 -> "INSTALL_FAILED_ALREADY_EXISTS"
        -2 -> "INSTALL_FAILED_INVALID_APK"
        -3 -> "INSTALL_FAILED_INVALID_URI"
        -4 -> "INSTALL_FAILED_INSUFFICIENT_STORAGE"
        -5 -> "INSTALL_FAILED_DUPLICATE_PACKAGE"
        -6 -> "INSTALL_FAILED_NO_SHARED_USER"
        -7 -> "INSTALL_FAILED_UPDATE_INCOMPATIBLE"
        -8 -> "INSTALL_FAILED_SHARED_USER_INCOMPATIBLE"
        -9 -> "INSTALL_FAILED_MISSING_SHARED_LIBRARY"
        -10 -> "INSTALL_FAILED_REPLACE_COULDNT_DELETE"
        -11 -> "INSTALL_FAILED_DEXOPT"
        -12 -> "INSTALL_FAILED_OLDER_SDK"
        -13 -> "INSTALL_FAILED_CONFLICTING_PROVIDER"
        -14 -> "INSTALL_FAILED_NEWER_SDK"
        -15 -> "INSTALL_FAILED_TEST_ONLY"
        -16 -> "INSTALL_FAILED_CPU_ABI_INCOMPATIBLE"
        -17 -> "INSTALL_FAILED_MISSING_FEATURE"
        -18 -> "INSTALL_FAILED_CONTAINER_ERROR"
        -19 -> "INSTALL_FAILED_INVALID_INSTALL_LOCATION"
        -20 -> "INSTALL_FAILED_MEDIA_UNAVAILABLE"
        -21 -> "INSTALL_FAILED_VERIFICATION_TIMEOUT"
        -22 -> "INSTALL_FAILED_VERIFICATION_FAILURE"
        -23 -> "INSTALL_FAILED_PACKAGE_CHANGED"
        -24 -> "INSTALL_FAILED_UID_CHANGED"
        -25 -> "INSTALL_FAILED_VERSION_DOWNGRADE"
        else -> ""
    }

/** Sends each artifact byte to both PackageInstaller and the private copy parsed before commit. */
private class InstallArtifactOutputStream(
    private val session: OutputStream,
    private val verification: OutputStream,
) : OutputStream() {
    override fun write(value: Int) {
        session.write(value)
        verification.write(value)
    }

    override fun write(buffer: ByteArray, offset: Int, length: Int) {
        session.write(buffer, offset, length)
        verification.write(buffer, offset, length)
    }

    override fun flush() {
        session.flush()
        verification.flush()
    }

    override fun close() {
        var failure: IOException? = null
        try {
            session.close()
        } catch (error: IOException) {
            failure = error
        }
        try {
            verification.close()
        } catch (error: IOException) {
            if (failure == null) failure = error else failure.addSuppressed(error)
        }
        failure?.let { throw it }
    }
}

/** A single streamed artifact copied to PackageInstaller and the private verification cache. */
class InstallArtifactWriter(
    val output: OutputStream,
    private val completed: (success: Boolean, sha256: ByteArray, bytesWritten: Long) -> Unit,
) {
    fun finish(success: Boolean, sha256: ByteArray, bytesWritten: Long) =
        completed(success, sha256, bytesWritten)
}
