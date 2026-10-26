package io.apkrun.store.store

import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.AbandonInstall
import io.apkrun.guest.protocol.v1.ArtifactSpec
import io.apkrun.guest.protocol.v1.CommitInstall
import io.apkrun.guest.protocol.v1.Event
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InstallMode
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.InstallStage
import io.apkrun.guest.protocol.v1.InstallStatus
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.OutputStream
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class InstallServiceTest {
    @get:Rule val temporaryFolder = TemporaryFolder()

    @Test
    fun beginCommitAndInstallStatusUsePackageInstallerSessionLifecycle() {
        val payload = "verified apk payload".toByteArray()
        val digest = sha256(payload)
        val installer = FakeStorePackageInstaller()
        val events = RecordingStoreEvents()
        val cache = temporaryFolder.newFolder("cache")
        val service =
            newService(
                installer = installer,
                events = events,
                verificationRoot = cache,
                inspector =
                    ArchiveInspector(
                        ArchiveReader { file ->
                            assertArrayEquals(payload, file.readBytes())
                            ArchiveFacts(
                                packageName = PACKAGE_NAME,
                                versionCode = 7,
                                versionName = "7.0",
                                splitName = "base",
                                nativeAbis = listOf("arm64-v8a"),
                                minSdk = 23,
                                targetSdk = 37,
                                signerSha256 = listOf(SIGNER),
                                signingSchemeVersion = 3,
                            )
                        }
                    ),
            )
        val begin =
            service.beginInstall(
                installRequest(payload, digest),
                setOf(StoreDispatcher.STORE_INSTALL_CAPABILITY),
                CONTROL_SESSION,
            )
        val session = installer.sessionFor(begin.androidSessionId)

        assertEquals(PACKAGE_NAME, installer.createdRequest?.expectedPackage)
        assertEquals(begin.installId, events.progress.single().installId)
        assertEquals(InstallStage.INSTALL_STAGE_RECEIVING, events.progress.single().stage)

        receiveArtifact(service, begin.installId, payload, digest)
        service.commitInstall(
            CommitInstall.newBuilder().setInstallId(begin.installId).build(),
            CONTROL_SESSION,
        )
        service.abandonControlSession(CONTROL_SESSION)

        assertEquals(listOf("fsync", "commit:${begin.installId}", "close"), session.calls)
        assertArrayEquals(payload, session.stored.getValue("base.apk"))
        assertEquals(
            listOf(
                InstallStage.INSTALL_STAGE_RECEIVING,
                InstallStage.INSTALL_STAGE_RECEIVING,
                InstallStage.INSTALL_STAGE_VERIFYING,
                InstallStage.INSTALL_STAGE_COMMITTING,
            ),
            events.progress.map { it.stage },
        )
        assertFalse(File(cache, begin.installId).exists())

        service.handleInstallStatus(
            installId = begin.installId,
            androidStatus = android.content.pm.PackageInstaller.STATUS_SUCCESS,
            legacyStatus = 0,
            message = "installed",
        )

        val finished = events.finished.single()
        assertEquals(InstallStatus.INSTALL_STATUS_SUCCESS, finished.status)
        assertEquals(7L, finished.installedVersionCode)
        assertEquals("installed", finished.message)
        assertEquals(0, finished.legacyStatus.length)
        service.handleInstallStatus(
            begin.installId,
            android.content.pm.PackageInstaller.STATUS_SUCCESS,
        )
        assertEquals(1, events.finished.size)
    }

    @Test
    fun controlDisconnectDuringArchiveInspectionAbandonsBeforePackageInstallerCommit() {
        val payload = "verified apk payload".toByteArray()
        val digest = sha256(payload)
        val inspectionStarted = CountDownLatch(1)
        val continueInspection = CountDownLatch(1)
        val installer = FakeStorePackageInstaller()
        val events = RecordingStoreEvents()
        val cache = temporaryFolder.newFolder("cache")
        val inspector =
            ArchiveInspector(
                ArchiveReader { file ->
                    assertArrayEquals(payload, file.readBytes())
                    inspectionStarted.countDown()
                    assertTrue(continueInspection.await(5, TimeUnit.SECONDS))
                    ArchiveFacts(
                        packageName = PACKAGE_NAME,
                        versionCode = 7,
                        versionName = "7.0",
                        splitName = "base",
                        nativeAbis = listOf("arm64-v8a"),
                        minSdk = 23,
                        targetSdk = 37,
                        signerSha256 = listOf(SIGNER),
                        signingSchemeVersion = 3,
                    )
                }
            )
        val service = newService(installer, events, cache, inspector)
        val begin =
            service.beginInstall(
                installRequest(payload, digest),
                setOf(StoreDispatcher.STORE_INSTALL_CAPABILITY),
                CONTROL_SESSION,
            )
        val session = installer.sessionFor(begin.androidSessionId)
        receiveArtifact(service, begin.installId, payload, digest)
        val executor = Executors.newSingleThreadExecutor()

        try {
            val commit = executor.submit {
                service.commitInstall(
                    CommitInstall.newBuilder().setInstallId(begin.installId).build(),
                    CONTROL_SESSION,
                )
            }
            assertTrue(inspectionStarted.await(5, TimeUnit.SECONDS))

            service.abandonControlSession(CONTROL_SESSION)
            assertEquals(listOf("fsync", "abandon", "close"), session.calls)
            continueInspection.countDown()
            commit.get(5, TimeUnit.SECONDS)

            assertEquals(listOf("fsync", "abandon", "close"), session.calls)
            assertTrue(events.finished.isEmpty())
            assertFalse(File(cache, begin.installId).exists())
        } finally {
            continueInspection.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun androidSignerAllowsInstallWhenHostCouldNotVerifyTheSignature() {
        val payload = "Android inspected signer".toByteArray()
        val digest = sha256(payload)
        val installer = FakeStorePackageInstaller()
        val events = RecordingStoreEvents()
        val cache = temporaryFolder.newFolder("cache")
        val service = newService(installer, events, cache)
        val begin =
            service.beginInstall(
                installRequest(payload, digest).toBuilder().clearExpectedSignerSha256().build(),
                setOf(StoreDispatcher.STORE_INSTALL_CAPABILITY),
                CONTROL_SESSION,
            )
        receiveArtifact(service, begin.installId, payload, digest)

        service.commitInstall(
            CommitInstall.newBuilder().setInstallId(begin.installId).build(),
            CONTROL_SESSION,
        )

        val session = installer.sessionFor(begin.androidSessionId)
        assertTrue(session.calls.any { it.startsWith("commit:") })
        assertArrayEquals(payload, session.stored.getValue("base.apk"))
        assertFalse(File(cache, begin.installId).exists())
    }

    @Test
    fun commitSecurityExceptionRemainsPermissionDeniedAndAbandonsStagingSession() {
        val payload = "verified apk payload".toByteArray()
        val digest = sha256(payload)
        val installer = FakeStorePackageInstaller()
        val events = RecordingStoreEvents()
        val cache = temporaryFolder.newFolder("cache")
        val service = newService(installer, events, cache)
        val begin =
            service.beginInstall(
                installRequest(payload, digest),
                setOf(StoreDispatcher.STORE_INSTALL_CAPABILITY),
                CONTROL_SESSION,
            )
        val session = installer.sessionFor(begin.androidSessionId)
        session.commitFailure = SecurityException("platform install privilege missing")
        receiveArtifact(service, begin.installId, payload, digest)

        val failure =
            org.junit.Assert.assertThrows(StoreFailure::class.java) {
                service.commitInstall(
                    CommitInstall.newBuilder().setInstallId(begin.installId).build(),
                    CONTROL_SESSION,
                )
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_PERMISSION_DENIED, failure.code)
        assertEquals(
            listOf("fsync", "commit:${begin.installId}", "abandon", "close"),
            session.calls,
        )
        assertFalse(File(cache, begin.installId).exists())
        assertEquals(1, events.progress.count { it.stage == InstallStage.INSTALL_STAGE_COMMITTING })
        assertTrue(events.finished.isEmpty())
        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
            org.junit.Assert.assertThrows(StoreFailure::class.java) {
                    service.abandonInstall(
                        AbandonInstall.newBuilder().setInstallId(begin.installId).build(),
                        CONTROL_SESSION,
                    )
                }
                .code,
        )
    }

    @Test
    fun stagedPackageMismatchEmitsInvalidAndAbandonsWithoutCommitting() {
        val payload = "wrong package".toByteArray()
        val digest = sha256(payload)
        val installer = FakeStorePackageInstaller()
        val events = RecordingStoreEvents()
        val cache = temporaryFolder.newFolder("cache")
        val inspector =
            ArchiveInspector(
                ArchiveReader {
                    ArchiveFacts(
                        packageName = "io.apkrun.fixture.other",
                        versionCode = 7,
                        versionName = "7",
                        splitName = "base",
                        nativeAbis = emptyList(),
                        minSdk = 23,
                        targetSdk = 37,
                        signerSha256 = listOf(SIGNER),
                        signingSchemeVersion = 3,
                    )
                }
            )
        val service = newService(installer, events, cache, inspector)
        val begin =
            service.beginInstall(
                installRequest(payload, digest),
                setOf(StoreDispatcher.STORE_INSTALL_CAPABILITY),
                CONTROL_SESSION,
            )
        val session = installer.sessionFor(begin.androidSessionId)
        receiveArtifact(service, begin.installId, payload, digest)

        service.commitInstall(
            CommitInstall.newBuilder().setInstallId(begin.installId).build(),
            CONTROL_SESSION,
        )

        assertEquals(listOf("fsync", "abandon", "close"), session.calls)
        assertEquals(InstallStatus.INSTALL_STATUS_INVALID, events.finished.single().status)
        assertEquals("INSTALL_FAILED_INVALID_APK", events.finished.single().legacyStatus)
        assertFalse(File(cache, begin.installId).exists())
    }

    @Test
    fun stagedArtifactDigestMismatchAbandonsInstallAndCannotBeCommitted() {
        val payload = "untrusted artifact".toByteArray()
        val digest = sha256(payload)
        val installer = FakeStorePackageInstaller()
        val service = newService(installer, RecordingStoreEvents(), temporaryFolder.newFolder())
        val begin =
            service.beginInstall(
                installRequest(payload, digest),
                setOf(StoreDispatcher.STORE_INSTALL_CAPABILITY),
                CONTROL_SESSION,
            )
        val session = installer.sessionFor(begin.androidSessionId)
        val writer =
            service.openArtifact(
                controlSessionId = CONTROL_SESSION,
                installId = begin.installId,
                name = "base.apk",
                size = payload.size.toLong(),
                declaredSha256 = digest,
            )
        writer.output.write(payload)
        writer.finish(
            success = true,
            sha256 = ByteArray(digest.size),
            bytesWritten = payload.size.toLong(),
        )

        assertEquals(listOf("abandon", "close"), session.calls)
        assertEquals(
            GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
            org.junit.Assert.assertThrows(StoreFailure::class.java) {
                    service.commitInstall(
                        CommitInstall.newBuilder().setInstallId(begin.installId).build(),
                        CONTROL_SESSION,
                    )
                }
                .code,
        )
    }

    @Test
    fun pendingUserActionEmitsTypedStatusAndAbandonsInstallerSession() {
        val payload = "verified apk payload".toByteArray()
        val digest = sha256(payload)
        val installer = FakeStorePackageInstaller()
        val events = RecordingStoreEvents()
        val service = newService(installer, events, temporaryFolder.newFolder())
        val begin =
            service.beginInstall(
                installRequest(payload, digest),
                setOf(StoreDispatcher.STORE_INSTALL_CAPABILITY),
                CONTROL_SESSION,
            )
        val session = installer.sessionFor(begin.androidSessionId)
        receiveArtifact(service, begin.installId, payload, digest)
        service.commitInstall(
            CommitInstall.newBuilder().setInstallId(begin.installId).build(),
            CONTROL_SESSION,
        )

        service.handleInstallStatus(
            installId = begin.installId,
            androidStatus = android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION,
            legacyStatus = -1,
            message = "user action required",
        )

        val finished = events.finished.single()
        assertEquals(InstallStatus.INSTALL_STATUS_USER_ACTION_REQUIRED, finished.status)
        assertEquals("user action required", finished.message)
        assertEquals("INSTALL_FAILED_ALREADY_EXISTS", finished.legacyStatus)
        assertEquals(
            listOf("fsync", "commit:${begin.installId}", "close", "abandon"),
            session.calls,
        )
    }

    @Test
    fun explicitAbandonAndIncompleteCommitKeepTheirTypedResults() {
        val payload = "verified apk payload".toByteArray()
        val digest = sha256(payload)
        val installer = FakeStorePackageInstaller()
        val service = newService(installer, RecordingStoreEvents(), temporaryFolder.newFolder())
        val begin =
            service.beginInstall(
                installRequest(payload, digest),
                setOf(StoreDispatcher.STORE_INSTALL_CAPABILITY),
                CONTROL_SESSION,
            )

        val incomplete =
            org.junit.Assert.assertThrows(StoreFailure::class.java) {
                service.commitInstall(
                    CommitInstall.newBuilder().setInstallId(begin.installId).build(),
                    CONTROL_SESSION,
                )
            }
        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_FAILED_PRECONDITION, incomplete.code)

        service.abandonInstall(
            AbandonInstall.newBuilder().setInstallId(begin.installId).build(),
            CONTROL_SESSION,
        )
        assertEquals(listOf("abandon", "close"), installer.sessionFor(begin.androidSessionId).calls)
    }

    @Test
    fun androidInstallStatusesAndLegacyFailuresMapToProtocolValues() {
        val cases =
            listOf(
                android.content.pm.PackageInstaller.STATUS_SUCCESS to
                    InstallStatus.INSTALL_STATUS_SUCCESS,
                android.content.pm.PackageInstaller.STATUS_FAILURE_ABORTED to
                    InstallStatus.INSTALL_STATUS_ABORTED,
                android.content.pm.PackageInstaller.STATUS_FAILURE_INCOMPATIBLE to
                    InstallStatus.INSTALL_STATUS_INCOMPATIBLE,
                android.content.pm.PackageInstaller.STATUS_FAILURE_CONFLICT to
                    InstallStatus.INSTALL_STATUS_CONFLICT,
                android.content.pm.PackageInstaller.STATUS_FAILURE_STORAGE to
                    InstallStatus.INSTALL_STATUS_STORAGE,
                android.content.pm.PackageInstaller.STATUS_FAILURE_INVALID to
                    InstallStatus.INSTALL_STATUS_INVALID,
                android.content.pm.PackageInstaller.STATUS_FAILURE_BLOCKED to
                    InstallStatus.INSTALL_STATUS_BLOCKED,
            )

        cases.forEach { (androidStatus, protocolStatus) ->
            assertEquals(protocolStatus, installStatusFromAndroid(androidStatus))
        }
        assertEquals(
            InstallStatus.INSTALL_STATUS_FAILURE,
            installStatusFromAndroid(Int.MIN_VALUE),
        )
        assertEquals(
            "INSTALL_FAILED_VERSION_DOWNGRADE",
            legacyInstallStatusName(-25),
        )
        assertEquals("", legacyInstallStatusName(0))
    }

    private fun newService(
        installer: FakeStorePackageInstaller,
        events: RecordingStoreEvents,
        verificationRoot: File,
        inspector: ArchiveInspector =
            ArchiveInspector(
                ArchiveReader {
                    ArchiveFacts(
                        packageName = PACKAGE_NAME,
                        versionCode = 7,
                        versionName = "7.0",
                        splitName = "base",
                        nativeAbis = listOf("arm64-v8a"),
                        minSdk = 23,
                        targetSdk = 37,
                        signerSha256 = listOf(SIGNER),
                        signingSchemeVersion = 3,
                    )
                }
            ),
    ): InstallService =
        InstallService(
            inspector = inspector,
            catalog = FixtureCatalog(),
            events = events,
            installer = installer,
            verificationRoot = verificationRoot,
            clockMillis = { 1_000L },
        )

    private fun installRequest(payload: ByteArray, digest: ByteArray): InstallRequest =
        InstallRequest.newBuilder()
            .setExpectedPackage(PACKAGE_NAME)
            .setExpectedVersionCode(7)
            .addExpectedSignerSha256(ByteString.copyFrom(SIGNER))
            .setMode(InstallMode.INSTALL_MODE_INSTALL_NEW)
            .addArtifacts(
                ArtifactSpec.newBuilder()
                    .setName("base.apk")
                    .setSize(payload.size.toLong())
                    .setSha256(ByteString.copyFrom(digest))
            )
            .build()

    private fun receiveArtifact(
        service: InstallService,
        installId: String,
        payload: ByteArray,
        digest: ByteArray,
    ) {
        val writer =
            service.openArtifact(
                controlSessionId = CONTROL_SESSION,
                installId = installId,
                name = "base.apk",
                size = payload.size.toLong(),
                declaredSha256 = digest,
            )
        writer.output.write(payload)
        writer.finish(success = true, sha256 = digest, bytesWritten = payload.size.toLong())
    }

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    private class FixtureCatalog : StorePackageCatalog {
        override fun find(packageName: String): StorePackageFacts? =
            if (packageName == PACKAGE_NAME) {
                StorePackageFacts(
                    packageName = PACKAGE_NAME,
                    versionCode = 7,
                    versionName = "7.0",
                    label = "Fixture",
                    installerOfRecord = "io.apkrun.store",
                    updateOwner = "",
                    initiatingPackage = "",
                    firstInstallTimeMillis = 1,
                    lastUpdateTimeMillis = 2,
                    minSdk = 23,
                    targetSdk = 37,
                    splits = listOf("base"),
                    nativeAbis = listOf("arm64-v8a"),
                    currentSignerSha256 = listOf(SIGNER),
                    pastSignerSha256 = emptyList(),
                    signingSchemeVersion = 3,
                    enabled = true,
                    suspended = false,
                    requestedPermissionsCount = 1,
                    userInstalled = true,
                )
            } else {
                null
            }

        override fun listInstalled(): List<StorePackageFacts> = listOfNotNull(find(PACKAGE_NAME))
    }

    private class RecordingStoreEvents : StoreEventSink {
        val events = mutableListOf<Event>()
        val progress
            get() = events.mapNotNull { event ->
                event.takeIf(Event::hasInstallProgress)?.installProgress
            }

        val finished
            get() = events.mapNotNull { event ->
                event.takeIf(Event::hasInstallFinished)?.installFinished
            }

        override fun publish(capability: String, build: (Event.Builder) -> Unit) {
            assertEquals(StoreDispatcher.STORE_INSTALL_CAPABILITY, capability)
            val event = Event.newBuilder()
            build(event)
            events += event.build()
        }
    }

    private class FakeStorePackageInstaller : StorePackageInstaller {
        var createdRequest: InstallRequest? = null
        val sessions = mutableMapOf<Int, FakeInstallSession>()

        override fun createSession(request: InstallRequest): Int {
            createdRequest = request
            sessions[SESSION_ID] = FakeInstallSession()
            return SESSION_ID
        }

        override fun openSession(sessionId: Int): StoreInstallSession =
            sessions[sessionId] ?: error("unexpected session $sessionId")

        override fun abandonSession(sessionId: Int) {
            sessions[sessionId]?.abandon()
        }

        override fun uninstall(packageName: String, keepData: Boolean, operationId: String) {
            error("uninstall is not expected in an install test")
        }

        fun sessionFor(sessionId: Int): FakeInstallSession =
            sessions[sessionId] ?: error("unexpected session $sessionId")
    }

    private class FakeInstallSession : StoreInstallSession {
        val calls = mutableListOf<String>()
        val stored = mutableMapOf<String, ByteArray>()
        var commitFailure: Exception? = null

        override fun openWrite(name: String, size: Long): OutputStream =
            object : ByteArrayOutputStream() {
                override fun close() {
                    super.close()
                    stored[name] = toByteArray()
                }
            }

        override fun fsync(output: OutputStream) {
            calls += "fsync"
        }

        override fun commit(installId: String) {
            calls += "commit:$installId"
            commitFailure?.let { throw it }
        }

        override fun abandon() {
            calls += "abandon"
        }

        override fun close() {
            calls += "close"
        }
    }

    private companion object {
        const val CONTROL_SESSION = "control-session"
        const val PACKAGE_NAME = "io.apkrun.fixture.hellotext"
        const val SESSION_ID = 41
        val SIGNER = ByteArray(32) { 0x5a }
    }
}
