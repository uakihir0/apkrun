package io.apkrun.store.store

import android.content.Context
import android.content.pm.PackageInstaller
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.Uninstall
import io.apkrun.guest.protocol.v1.UninstallResult
import io.apkrun.guest.protocol.v1.UninstallStatus
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Implements privileged uninstall requests and preserves package data when requested. */
class UninstallService
internal constructor(
    private val installer: StorePackageInstaller,
    private val timeoutMillis: Long = UNINSTALL_TIMEOUT_MILLIS,
) {
    constructor(context: Context) : this(AndroidStorePackageInstaller(context))

    private val pending = ConcurrentHashMap<String, CompletableFuture<UninstallResult>>()

    fun uninstall(request: Uninstall): UninstallResult {
        val packageName = request.getPackage()
        if (!PackageName.isValid(packageName)) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "package is not a valid Android package name",
            )
        }
        val operationId = UUID.randomUUID().toString()
        val result = CompletableFuture<UninstallResult>()
        pending[operationId] = result
        try {
            installer.uninstall(packageName, request.keepData, operationId)
            return result.get(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (_: java.util.concurrent.TimeoutException) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT,
                "Android did not finish uninstalling the package before the deadline",
            )
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_CANCELLED,
                "the uninstall wait was interrupted",
            )
        } catch (error: java.util.concurrent.ExecutionException) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INTERNAL,
                "Android could not report the uninstall result",
                mapOf("exception" to (error.cause?.javaClass?.name ?: error.javaClass.name)),
            )
        } catch (error: SecurityException) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_PERMISSION_DENIED,
                "Android refused to uninstall the package",
            )
        } catch (error: IllegalArgumentException) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                "the package is not installed",
            )
        } finally {
            pending.remove(operationId)
        }
    }

    fun complete(operationId: String, status: Int, message: String) {
        val result =
            if (status == PackageInstaller.STATUS_SUCCESS) {
                UninstallResult.newBuilder()
                    .setStatus(UninstallStatus.UNINSTALL_STATUS_SUCCESS)
                    .setMessage(message)
                    .build()
            } else {
                UninstallResult.newBuilder()
                    .setStatus(UninstallStatus.UNINSTALL_STATUS_FAILURE)
                    .setMessage(message.take(MAXIMUM_MESSAGE_LENGTH))
                    .build()
            }
        pending[operationId]?.complete(result)
    }

    private companion object {
        const val UNINSTALL_TIMEOUT_MILLIS = 120_000L
        const val MAXIMUM_MESSAGE_LENGTH = 1_024
    }
}
