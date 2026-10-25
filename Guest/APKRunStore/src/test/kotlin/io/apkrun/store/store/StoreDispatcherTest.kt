package io.apkrun.store.store

import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.AbandonInstall
import io.apkrun.guest.protocol.v1.ArchiveInfo
import io.apkrun.guest.protocol.v1.ArtifactRef
import io.apkrun.guest.protocol.v1.BeginInstallResult
import io.apkrun.guest.protocol.v1.CommitInstall
import io.apkrun.guest.protocol.v1.GetPackageMetadata
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InspectArchive
import io.apkrun.guest.protocol.v1.InstallMode
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.ListManagedPackages
import io.apkrun.guest.protocol.v1.ManagedPackageFilter
import io.apkrun.guest.protocol.v1.Ping
import io.apkrun.guest.protocol.v1.Request
import io.apkrun.guest.protocol.v1.Response
import io.apkrun.guest.protocol.v1.StorePackageInfo
import io.apkrun.guest.protocol.v1.StorePackageList
import io.apkrun.guest.protocol.v1.Uninstall
import io.apkrun.guest.protocol.v1.UninstallResult
import io.apkrun.guest.protocol.v1.UninstallStatus
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StoreDispatcherTest {
    private val operations = RecordingStoreOperations()
    private val dispatcher = StoreDispatcher(operations, uptimeMillis = { 1_234L })
    private val nextRequestId = AtomicLong(1)

    @Test
    fun inspectArchiveDispatchesOperation100() {
        val request =
            Request.newBuilder()
                .setInspectArchive(
                    InspectArchive.newBuilder()
                        .addArtifacts(ArtifactRef.newBuilder().setTransferId(41).setName("base"))
                )
                .build()

        val response = dispatch(request, setOf(METADATA))

        assertEquals(Response.ResultCase.INSPECT_ARCHIVE, response.resultCase)
        assertEquals("com.example.app", response.inspectArchive.getPackage())
        assertEquals("inspect:41:base", operations.calls.single())
    }

    @Test
    fun beginInstallDispatchesOperation101AndPreservesControlSession() {
        val request = Request.newBuilder().setBeginInstall(validInstallRequest()).build()

        val response = dispatch(request, setOf(INSTALL))

        assertEquals(Response.ResultCase.BEGIN_INSTALL, response.resultCase)
        assertEquals("install-1", response.beginInstall.installId)
        assertEquals(17, response.beginInstall.androidSessionId)
        assertEquals("begin:com.example.app:$CONTROL_ID", operations.calls.single())
    }

    @Test
    fun commitInstallDispatchesOperation102() {
        val request =
            Request.newBuilder()
                .setCommitInstall(CommitInstall.newBuilder().setInstallId("install-2"))
                .build()

        val response = dispatch(request, setOf(INSTALL))

        assertEquals(Response.ResultCase.COMMIT_INSTALL, response.resultCase)
        assertEquals("commit:install-2:$CONTROL_ID", operations.calls.single())
    }

    @Test
    fun abandonInstallDispatchesOperation103() {
        val request =
            Request.newBuilder()
                .setAbandonInstall(AbandonInstall.newBuilder().setInstallId("install-3"))
                .build()

        val response = dispatch(request, setOf(INSTALL))

        assertEquals(Response.ResultCase.ABANDON_INSTALL, response.resultCase)
        assertEquals("abandon:install-3:$CONTROL_ID", operations.calls.single())
    }

    @Test
    fun uninstallDispatchesOperation104() {
        val request =
            Request.newBuilder()
                .setUninstall(
                    Uninstall.newBuilder().setPackage("com.example.app").setKeepData(true)
                )
                .build()

        val response = dispatch(request, setOf(INSTALL))

        assertEquals(Response.ResultCase.UNINSTALL, response.resultCase)
        assertEquals(UninstallStatus.UNINSTALL_STATUS_SUCCESS, response.uninstall.status)
        assertEquals("uninstall:com.example.app:true", operations.calls.single())
    }

    @Test
    fun getPackageMetadataDispatchesOperation105() {
        val request =
            Request.newBuilder()
                .setGetPackageMetadata(
                    GetPackageMetadata.newBuilder().setPackage("com.example.app")
                )
                .build()

        val response = dispatch(request, setOf(METADATA))

        assertEquals(Response.ResultCase.GET_PACKAGE_METADATA, response.resultCase)
        assertEquals("com.example.app", response.getPackageMetadata.getPackage())
        assertEquals("metadata:com.example.app", operations.calls.single())
    }

    @Test
    fun listManagedPackagesDispatchesOperation106() {
        val request =
            Request.newBuilder()
                .setListManagedPackages(
                    ListManagedPackages.newBuilder()
                        .setFilter(ManagedPackageFilter.MANAGED_PACKAGE_FILTER_ALL_USER_INSTALLED)
                )
                .build()

        val response = dispatch(request, setOf(METADATA))

        assertEquals(Response.ResultCase.LIST_MANAGED_PACKAGES, response.resultCase)
        assertEquals(
            "com.example.app",
            response.listManagedPackages.packagesList.single().getPackage(),
        )
        assertEquals("list:MANAGED_PACKAGE_FILTER_ALL_USER_INSTALLED", operations.calls.single())
    }

    @Test
    fun missingCapabilityReturnsUnsupportedWithoutCallingOperation() {
        val request =
            Request.newBuilder()
                .setGetPackageMetadata(
                    GetPackageMetadata.newBuilder().setPackage("com.example.app")
                )
                .build()

        val response = dispatch(request, emptySet())

        assertEquals(Response.ResultCase.ERROR, response.resultCase)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, response.error.code)
        assertTrue(operations.calls.isEmpty())
    }

    @Test
    fun operations107Through110RemainUnsupported() {
        val requests =
            listOf(
                Request.newBuilder()
                    .setRenderIcon(io.apkrun.guest.protocol.v1.RenderIcon.getDefaultInstance())
                    .build(),
                Request.newBuilder()
                    .setRollbackPackage(
                        io.apkrun.guest.protocol.v1.RollbackPackage.getDefaultInstance()
                    )
                    .build(),
                Request.newBuilder()
                    .setRelinquishUpdateOwnership(
                        io.apkrun.guest.protocol.v1.RelinquishUpdateOwnership.getDefaultInstance()
                    )
                    .build(),
                Request.newBuilder()
                    .setCheckInstallConstraints(
                        io.apkrun.guest.protocol.v1.CheckInstallConstraints.getDefaultInstance()
                    )
                    .build(),
            )

        requests.forEach { request ->
            val response = dispatch(request, setOf(INSTALL, METADATA))
            assertEquals(Response.ResultCase.ERROR, response.resultCase)
            assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, response.error.code)
        }
        assertTrue(operations.calls.isEmpty())
    }

    @Test
    fun emptyRequestIsUnsupported() {
        val response =
            dispatch(
                Request.getDefaultInstance(),
                setOf(INSTALL, METADATA),
            )

        assertEquals(Response.ResultCase.ERROR, response.resultCase)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, response.error.code)
        assertTrue(operations.calls.isEmpty())
    }

    @Test
    fun pingEchoesNonceAndReportsUptimeWhenCoreIsEnabled() {
        val request = Request.newBuilder().setPing(Ping.newBuilder().setNonce(9_876L)).build()

        val response = dispatch(request, setOf(StoreDispatcher.CORE_CAPABILITY))

        assertEquals(Response.ResultCase.PING, response.resultCase)
        assertEquals(9_876L, response.ping.nonce)
        assertEquals(1_234L, response.ping.guestUptimeMs)
        assertEquals(
            StoreDispatcher.CORE_CAPABILITY,
            StoreDispatcher.requiredCapability(request.opCase),
        )
    }

    @Test
    fun pingRequiresCoreCapability() {
        val request = Request.newBuilder().setPing(Ping.newBuilder().setNonce(9_876L)).build()

        val response = dispatch(request, emptySet())

        assertEquals(Response.ResultCase.ERROR, response.resultCase)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_UNSUPPORTED, response.error.code)
        assertTrue(operations.calls.isEmpty())
    }

    @Test
    fun blockedUninstallDoesNotBlockPingAndCancelReturnsCancelled() = runBlocking {
        val entered = CountDownLatch(1)
        val dispatcher =
            StoreDispatcher(
                BlockingUninstallStoreOperations(entered),
                uptimeMillis = { 5_678L },
                defaultTimeoutMillis = 5_000L,
            )
        val uninstallId = 101L
        val uninstallRequest =
            Request.newBuilder()
                .setUninstall(Uninstall.newBuilder().setPackage("com.example.app"))
                .build()
        val uninstall = async {
            dispatcher.dispatch(uninstallId, uninstallRequest, setOf(INSTALL), CONTROL_ID)
        }

        assertTrue(withContext(Dispatchers.IO) { entered.await(5, TimeUnit.SECONDS) })

        val ping =
            dispatcher.dispatch(
                102L,
                Request.newBuilder().setPing(Ping.newBuilder().setNonce(77L)).build(),
                setOf(StoreDispatcher.CORE_CAPABILITY),
                CONTROL_ID,
            )
        assertEquals(Response.ResultCase.PING, ping.resultCase)
        assertEquals(77L, ping.ping.nonce)

        dispatcher.cancel("a-different-control-session", uninstallId)
        assertTrue(uninstall.isActive)
        dispatcher.cancel(CONTROL_ID, uninstallId)
        val cancelled = uninstall.await()
        assertEquals(Response.ResultCase.ERROR, cancelled.resultCase)
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_CANCELLED, cancelled.error.code)
    }

    private fun dispatch(request: Request, capabilities: Set<String>): Response = runBlocking {
        dispatcher.dispatch(nextRequestId.getAndIncrement(), request, capabilities, CONTROL_ID)
    }

    private open class RecordingStoreOperations : StoreOperations {
        val calls = mutableListOf<String>()

        override fun inspectArchive(request: InspectArchive): ArchiveInfo {
            val ref = request.artifactsList.single()
            calls += "inspect:${ref.transferId}:${ref.name}"
            return ArchiveInfo.newBuilder().setPackage("com.example.app").build()
        }

        override fun beginInstall(
            request: InstallRequest,
            enabledCapabilities: Set<String>,
            controlSessionId: String,
        ): BeginInstallResult {
            calls += "begin:${request.expectedPackage}:$controlSessionId"
            return BeginInstallResult.newBuilder()
                .setInstallId("install-1")
                .setAndroidSessionId(17)
                .build()
        }

        override fun commitInstall(request: CommitInstall, controlSessionId: String) {
            calls += "commit:${request.installId}:$controlSessionId"
        }

        override fun abandonInstall(request: AbandonInstall, controlSessionId: String) {
            calls += "abandon:${request.installId}:$controlSessionId"
        }

        override fun uninstall(request: Uninstall): UninstallResult {
            calls += "uninstall:${request.getPackage()}:${request.keepData}"
            return UninstallResult.newBuilder()
                .setStatus(UninstallStatus.UNINSTALL_STATUS_SUCCESS)
                .build()
        }

        override fun getPackageMetadata(request: GetPackageMetadata): StorePackageInfo {
            calls += "metadata:${request.getPackage()}"
            return StorePackageInfo.newBuilder().setPackage(request.getPackage()).build()
        }

        override fun listManagedPackages(request: ListManagedPackages): StorePackageList {
            calls += "list:${request.filter.name}"
            return StorePackageList.newBuilder()
                .addPackages(StorePackageInfo.newBuilder().setPackage("com.example.app"))
                .build()
        }
    }

    private class BlockingUninstallStoreOperations(private val entered: CountDownLatch) :
        RecordingStoreOperations() {
        override fun uninstall(request: Uninstall): UninstallResult {
            entered.countDown()
            CountDownLatch(1).await()
            return UninstallResult.newBuilder()
                .setStatus(UninstallStatus.UNINSTALL_STATUS_SUCCESS)
                .build()
        }
    }

    private companion object {
        const val CONTROL_ID = "control-session-1"
        const val INSTALL = StoreDispatcher.STORE_INSTALL_CAPABILITY
        const val METADATA = StoreDispatcher.STORE_METADATA_CAPABILITY

        fun validInstallRequest(): InstallRequest =
            InstallRequest.newBuilder()
                .setExpectedPackage("com.example.app")
                .setExpectedVersionCode(1)
                .addExpectedSignerSha256(ByteString.copyFrom(ByteArray(32) { 0x41 }))
                .setMode(InstallMode.INSTALL_MODE_INSTALL_NEW)
                .setInstallReason(4)
                .setPackageSource(1)
                .addArtifacts(
                    io.apkrun.guest.protocol.v1.ArtifactSpec.newBuilder()
                        .setName("base")
                        .setSize(4)
                        .setSha256(ByteString.copyFrom(ByteArray(32) { 0x42 }))
                )
                .build()
    }
}
