package io.apkrun.store.store

import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InstallMode
import io.apkrun.guest.protocol.v1.InstallRequest

/**
 * Validates the wire-level install invariants in guest-protocol.md §11.3 before opening a session.
 */
object InstallRequestValidator {
    const val MAXIMUM_ARTIFACT_BYTES = 2L * 1024 * 1024 * 1024

    fun validate(
        request: InstallRequest,
        enabledCapabilities: Set<String>,
    ) {
        if (request.installReason != INSTALL_REASON_USER) {
            invalid("install_reason must be INSTALL_REASON_USER")
        }
        if (request.packageSource != PACKAGE_SOURCE_OTHER) {
            invalid("package_source must be PACKAGE_SOURCE_OTHER")
        }
        if (request.allowDowngrade) {
            invalid("downgrade installs are not supported")
        }
        if (request.requestUpdateOwnership && STORE_OWNERSHIP_CAPABILITY !in enabledCapabilities) {
            invalid("request_update_ownership requires store.ownership.v1")
        }
        if (request.enableRollback && request.mode != InstallMode.INSTALL_MODE_UPDATE) {
            invalid("rollback is available only for update installs")
        }
        if (request.enableRollback && STORE_ROLLBACK_CAPABILITY !in enabledCapabilities) {
            invalid("enable_rollback requires store.rollback.v1")
        }
        if (!PackageName.isValid(request.expectedPackage)) {
            invalid("expected_package is not a valid Android package name")
        }
        if (request.expectedVersionCode < 0) {
            invalid("expected_version_code must not be negative")
        }
        if (
            request.mode == InstallMode.INSTALL_MODE_UNSPECIFIED ||
                request.mode == InstallMode.UNRECOGNIZED
        ) {
            invalid("mode must be INSTALL_NEW, UPDATE, or REINSTALL")
        }
        if (request.expectedSignerSha256List.any { it.size() != SHA256_BYTES }) {
            invalid("expected_signer_sha256 entries must be SHA-256 digests")
        }
        if (request.artifactsCount == 0) {
            invalid("at least one install artifact is required")
        }
        val names = mutableSetOf<String>()
        var totalBytes = 0L
        for (artifact in request.artifactsList) {
            if (!isSafeArtifactName(artifact.name)) {
                invalid("an artifact name is invalid")
            }
            if (!names.add(artifact.name)) {
                invalid("artifact names must be unique")
            }
            if (artifact.size <= 0 || artifact.size > MAXIMUM_ARTIFACT_BYTES) {
                invalid("an artifact size is outside the supported range")
            }
            if (artifact.sha256.size() != SHA256_BYTES) {
                invalid("artifact sha256 entries must be SHA-256 digests")
            }
            if (totalBytes > MAXIMUM_INSTALL_BYTES - artifact.size) {
                invalid("the install set is too large")
            }
            totalBytes += artifact.size
        }
    }

    private fun invalid(message: String): Nothing =
        throw StoreFailure(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, message)

    private fun isSafeArtifactName(value: String): Boolean =
        value.isNotBlank() &&
            value.length <= 255 &&
            value != "." &&
            value != ".." &&
            '/' !in value &&
            '\\' !in value &&
            value.none(Char::isISOControl)

    private const val SHA256_BYTES = 32
    private const val MAXIMUM_INSTALL_BYTES = 8L * 1024 * 1024 * 1024
    // Protocol v1 uses the Android PackageManager and PackageInstaller enum values.
    private const val INSTALL_REASON_USER = 4
    private const val PACKAGE_SOURCE_OTHER = 1
    private const val STORE_OWNERSHIP_CAPABILITY = "store.ownership.v1"
    private const val STORE_ROLLBACK_CAPABILITY = "store.rollback.v1"
}

/** Android package names are dot-separated Java identifiers with at least two segments. */
object PackageName {
    private val pattern = Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")

    fun isValid(value: String): Boolean = value.length <= 255 && pattern.matches(value)
}
