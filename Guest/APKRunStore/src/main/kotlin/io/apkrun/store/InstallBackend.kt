package io.apkrun.store

import java.io.File
import java.io.OutputStream

/**
 * The Android seam of [InstallService] (guest-components.md §8.2). The device implements it on top
 * of `PackageInstaller` and `PackageManager`; tests implement it in plain Kotlin so the session
 * bookkeeping of [InstallService] runs on the JVM.
 */
interface InstallBackend {
    /** Opens a PackageInstaller session for the request and returns its handle. */
    fun createSession(parameters: SessionParameters): SessionHandle

    /**
     * Removes [packageName], keeping its data when [keepData]; the answer arrives on [onResult].
     */
    fun uninstall(packageName: String, keepData: Boolean, onResult: (UninstallOutcome) -> Unit)

    /**
     * Android's own parse of a staged artifact (PackageManager.getPackageArchiveInfo), the
     * defense-in-depth check of guest-protocol.md §11.3.
     */
    fun stagedArchiveInfo(path: File): StagedArchiveInfo?

    /** The session's status arrived from the broadcast receiver. */
    var onFinished: ((androidSessionId: Int, status: Int, message: String) -> Unit)?
}

/** The install parameters the agent applies to one session. */
data class SessionParameters(
    val packageName: String,
    val requestUpdateOwnership: Boolean,
    val enableRollback: Boolean,
    val installReason: Int,
    val packageSource: Int,
)

/** One open PackageInstaller session. */
interface SessionHandle {
    val androidSessionId: Int

    /** Streams one artifact into the session (PackageInstaller.Session.openWrite). */
    fun openWrite(name: String, offset: Long, size: Long): OutputStream

    /** Commits the session. The status arrives on [InstallBackend.onFinished]. */
    fun commit()

    /** Abandons the session. Idempotent. */
    fun abandon()
}

/** What Android's parser reports for one staged artifact. */
data class StagedArchiveInfo(
    val packageName: String,
    val versionCode: Long,
    val signerSha256: List<ByteArray>,
)

/** The answer of one uninstall. */
data class UninstallOutcome(val success: Boolean, val message: String)
