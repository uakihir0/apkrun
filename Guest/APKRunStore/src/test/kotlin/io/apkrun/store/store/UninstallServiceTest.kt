package io.apkrun.store.store

import android.content.pm.PackageInstaller
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.Uninstall
import io.apkrun.guest.protocol.v1.UninstallStatus
import org.junit.Assert.assertEquals
import org.junit.Test

class UninstallServiceTest {
    @Test
    fun uninstallPassesKeepDataAndConvertsPackageInstallerSuccess() {
        val installer = FakeStorePackageInstaller()
        lateinit var service: UninstallService
        installer.onUninstall = { packageName, keepData, operationId ->
            assertEquals(PACKAGE_NAME, packageName)
            assertEquals(true, keepData)
            service.complete(operationId, PackageInstaller.STATUS_SUCCESS, "removed")
        }
        service = UninstallService(installer)

        val result =
            service.uninstall(
                Uninstall.newBuilder().setPackage(PACKAGE_NAME).setKeepData(true).build()
            )

        assertEquals(UninstallStatus.UNINSTALL_STATUS_SUCCESS, result.status)
        assertEquals("removed", result.message)
        assertEquals(PACKAGE_NAME, installer.uninstalledPackage)
        assertEquals(true, installer.keepData)
    }

    @Test
    fun packageInstallerFailureIsReturnedAsUninstallFailure() {
        val installer = FakeStorePackageInstaller()
        lateinit var service: UninstallService
        val failureMessage = "x".repeat(1_200)
        installer.onUninstall = { _, _, operationId ->
            service.complete(operationId, PackageInstaller.STATUS_FAILURE, failureMessage)
        }
        service = UninstallService(installer)

        val result =
            service.uninstall(
                Uninstall.newBuilder().setPackage(PACKAGE_NAME).setKeepData(false).build()
            )

        assertEquals(UninstallStatus.UNINSTALL_STATUS_FAILURE, result.status)
        assertEquals(1_024, result.message.length)
        assertEquals(false, installer.keepData)
    }

    @Test
    fun uninstallPermissionDenialAndMissingPackageKeepTypedFailures() {
        val denied =
            UninstallService(
                FakeStorePackageInstaller().apply {
                    uninstallFailure = SecurityException("missing delete privilege")
                }
            )
        val missing =
            UninstallService(
                FakeStorePackageInstaller().apply {
                    uninstallFailure = IllegalArgumentException("package absent")
                }
            )
        val request = Uninstall.newBuilder().setPackage(PACKAGE_NAME).build()

        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_PERMISSION_DENIED,
            org.junit.Assert.assertThrows(StoreFailure::class.java) {
                    denied.uninstall(request)
                }
                .code,
        )
        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
            org.junit.Assert.assertThrows(StoreFailure::class.java) {
                    missing.uninstall(request)
                }
                .code,
        )
    }

    @Test
    fun uninstallWaitUsesTimeoutFailure() {
        val service = UninstallService(FakeStorePackageInstaller(), timeoutMillis = 1)

        val failure =
            org.junit.Assert.assertThrows(StoreFailure::class.java) {
                service.uninstall(Uninstall.newBuilder().setPackage(PACKAGE_NAME).build())
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_TIMEOUT, failure.code)
    }

    private class FakeStorePackageInstaller(var uninstallFailure: RuntimeException? = null) :
        StorePackageInstaller {
        var onUninstall: (packageName: String, keepData: Boolean, operationId: String) -> Unit =
            { _, _, _ ->
            }
        var uninstalledPackage: String? = null
        var keepData: Boolean? = null

        override fun createSession(request: InstallRequest): Int =
            error("install is not expected in an uninstall test")

        override fun openSession(sessionId: Int): StoreInstallSession =
            error("install is not expected in an uninstall test")

        override fun abandonSession(sessionId: Int) =
            error("install is not expected in an uninstall test")

        override fun uninstall(packageName: String, keepData: Boolean, operationId: String) {
            uninstalledPackage = packageName
            this.keepData = keepData
            uninstallFailure?.let { throw it }
            onUninstall(packageName, keepData, operationId)
        }
    }

    private companion object {
        const val PACKAGE_NAME = "io.apkrun.fixture.hellotext"
    }
}
