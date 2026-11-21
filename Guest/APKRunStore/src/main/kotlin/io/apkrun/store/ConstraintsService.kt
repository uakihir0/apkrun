package io.apkrun.store

import android.content.pm.PackageInstaller
import io.apkrun.guest.protocol.GuestFailure
import io.apkrun.guest.protocol.v1.CheckInstallConstraints
import io.apkrun.guest.protocol.v1.ConstraintsResult
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InstallConstraint
import io.apkrun.guest.protocol.v1.PackageConstraint
import io.apkrun.guest.runtime.AgentLog
import java.util.concurrent.Executor
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The CheckInstallConstraints operation (op 110, guest-protocol.md §11.1): the agent calls
 * `PackageInstaller.checkInstallConstraints` with `InstallConstraints` (API 34) built from the
 * request's flags. It answers on the callback, or with `TIMEOUT` after 10 s — the caller never
 * waits for the constraints to hold. The result is a hint only; the gentle-update gate re-evaluates
 * before each install (update-system.md §7.1 GU5).
 */
class ConstraintsService(
    private val packageInstaller: PackageInstaller,
    private val callbackExecutor: Executor,
) {
    constructor(packageInstaller: PackageInstaller) : this(packageInstaller, Executor { it.run() })

    suspend fun checkInstallConstraints(request: CheckInstallConstraints): ConstraintsResult {
        val constraints =
            when (request.constraint) {
                InstallConstraint.INSTALL_CONSTRAINT_GENTLE_UPDATE -> constraintsOf(request)
                else ->
                    throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "unsupported install constraint ${request.constraint}",
                    )
            }
        val packages = request.packagesList
        if (packages.isEmpty()) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "check_install_constraints needs at least one package",
            )
        }

        val result = CompletableDeferred<Boolean>()
        try {
            packageInstaller.checkInstallConstraints(packages, constraints, callbackExecutor) {
                result.complete(it.areAllConstraintsSatisfied())
            }
        } catch (failure: SecurityException) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION,
                "checkInstallConstraints was refused",
            )
        }

        val satisfied =
            withTimeoutOrNull(TIMEOUT_MILLIS) { result.await() }
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT,
                    "checkInstallConstraints did not answer within 10 s",
                )
        AgentLog.info("install constraints satisfied=$satisfied for ${packages.joinToString()}")

        val builder = ConstraintsResult.newBuilder()
        for (packageName in packages) {
            builder.addResults(
                PackageConstraint.newBuilder().setPackage(packageName).setSatisfied(satisfied)
            )
        }
        return builder.build()
    }

    private fun constraintsOf(
        request: CheckInstallConstraints
    ): PackageInstaller.InstallConstraints {
        val builder = PackageInstaller.InstallConstraints.Builder()
        if (request.appNotForegroundRequired) {
            builder.setAppNotForegroundRequired()
        }
        if (request.appNotInteractingRequired) {
            builder.setAppNotInteractingRequired()
        }
        if (request.appNotTopVisibleRequired) {
            builder.setAppNotTopVisibleRequired()
        }
        // GENTLE_UPDATE is the preset for a request without extra flags; the flags only tighten it.
        return if (
            request.appNotForegroundRequired ||
                request.appNotInteractingRequired ||
                request.appNotTopVisibleRequired
        ) {
            builder.build()
        } else {
            PackageInstaller.InstallConstraints.GENTLE_UPDATE
        }
    }

    companion object {
        const val TIMEOUT_MILLIS = 10_000L
    }
}
