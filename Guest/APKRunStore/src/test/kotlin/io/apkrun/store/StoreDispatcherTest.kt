package io.apkrun.store

import io.apkrun.guest.protocol.GuestCapability
import io.apkrun.guest.protocol.v1.BeginInstallResult
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.ListManagedPackages
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.StorePackageInfo
import io.apkrun.guest.protocol.v1.StorePackageList
import io.apkrun.guest.protocol.v1.Uninstall
import io.apkrun.guest.protocol.v1.UninstallResult
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

private class FakeStoreOperations : StoreOperations {
    val began = AtomicInteger(0)
    val relinquished = AtomicInteger(0)

    override fun beginInstall(request: InstallRequest): BeginInstallResult {
        began.incrementAndGet()
        return BeginInstallResult.newBuilder().setInstallId("install-1").build()
    }

    override fun commitInstall(installId: String) = Unit

    override fun abandonInstall(installId: String) = Unit

    override fun uninstall(request: Uninstall): UninstallResult =
        UninstallResult.getDefaultInstance()

    override fun getPackageMetadata(packageName: String): StorePackageInfo? = null

    override fun listManagedPackages(request: ListManagedPackages): StorePackageList =
        StorePackageList.getDefaultInstance()

    override fun relinquishUpdateOwnership(packageName: String) {
        relinquished.incrementAndGet()
    }
}

/**
 * The capability gates of `BeginInstall` (guest-protocol.md §11.3): a flag that needs a capability
 * the host did not enable is INVALID_ARGUMENT, not UNSUPPORTED.
 */
class StoreDispatcherTest {
    private val operations = FakeStoreOperations()
    private val dispatcher = StoreDispatcher(operations, uptimeMillis = { 0 })

    private fun beginInstall(requestOwnership: Boolean = false, rollback: Boolean = false) =
        Request.newBuilder()
            .setBeginInstall(
                InstallRequest.newBuilder()
                    .setRequestUpdateOwnership(requestOwnership)
                    .setEnableRollback(rollback)
                    .setExpectedPackage("io.example.app")
            )
            .build()

    @Test
    fun requestUpdateOwnershipWithoutCapabilityIsInvalidArgument() = runBlocking {
        val response =
            dispatcher.dispatch(
                1,
                beginInstall(requestOwnership = true),
                enabled = setOf(GuestCapability.STORE_INSTALL),
            )
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, response.error.code)
        assertEquals(0, operations.began.get())
    }

    @Test
    fun requestUpdateOwnershipWithCapabilityReachesTheOperation() = runBlocking {
        val response =
            dispatcher.dispatch(
                1,
                beginInstall(requestOwnership = true),
                enabled = setOf(GuestCapability.STORE_INSTALL, GuestCapability.STORE_OWNERSHIP),
            )
        assertTrue(response.hasBeginInstall())
        assertEquals(1, operations.began.get())
    }

    @Test
    fun enableRollbackWithoutCapabilityIsInvalidArgument() = runBlocking {
        val response =
            dispatcher.dispatch(
                1,
                beginInstall(rollback = true),
                enabled = setOf(GuestCapability.STORE_INSTALL),
            )
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, response.error.code)
        assertEquals(0, operations.began.get())
    }

    @Test
    fun beginInstallWithoutInstallCapabilityIsUnsupported() = runBlocking {
        val response = dispatcher.dispatch(1, beginInstall(), enabled = setOf(GuestCapability.CORE))
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, response.error.code)
        assertEquals(0, operations.began.get())
    }

    @Test
    fun relinquishNeedsTheOwnershipCapability() = runBlocking {
        val request =
            Request.newBuilder()
                .setRelinquishUpdateOwnership(
                    io.apkrun.guest.protocol.v1.RelinquishUpdateOwnership.newBuilder()
                        .setPackage("io.example.app")
                )
                .build()
        val refused = dispatcher.dispatch(1, request, enabled = setOf(GuestCapability.CORE))
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, refused.error.code)
        assertEquals(0, operations.relinquished.get())

        val allowed =
            dispatcher.dispatch(2, request, enabled = setOf(GuestCapability.STORE_OWNERSHIP))
        assertTrue(allowed.hasRelinquishUpdateOwnership())
        assertEquals(1, operations.relinquished.get())
    }
}
