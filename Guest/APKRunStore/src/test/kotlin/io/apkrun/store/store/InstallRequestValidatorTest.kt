package io.apkrun.store.store

import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.ArtifactSpec
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.InstallMode
import io.apkrun.guest.protocol.v1.InstallRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallRequestValidatorTest {
    @Test
    fun acceptsCanonicalUserOtherInstallRequest() {
        InstallRequestValidator.validate(validRequest(), emptySet())
    }

    @Test
    fun rejectsNonUserInstallReasons() {
        listOf(0, 1, 2, 3, 5, 6, Int.MIN_VALUE, Int.MAX_VALUE).forEach { installReason ->
            assertInvalidArgument(
                validRequest().toBuilder().setInstallReason(installReason).build(),
                emptySet(),
            )
        }
    }

    @Test
    fun rejectsNonOtherPackageSources() {
        listOf(0, 2, 3, 4, Int.MIN_VALUE, Int.MAX_VALUE).forEach { packageSource ->
            assertInvalidArgument(
                validRequest().toBuilder().setPackageSource(packageSource).build(),
                emptySet(),
            )
        }
    }

    @Test
    fun rejectsDowngradeRequests() {
        assertInvalidArgument(
            validRequest().toBuilder().setAllowDowngrade(true).build(),
            emptySet(),
        )
    }

    @Test
    fun rejectsRollbackForInstallNew() {
        assertInvalidArgument(
            validRequest().toBuilder().setEnableRollback(true).build(),
            setOf(ROLLBACK),
        )
    }

    @Test
    fun rejectsRollbackWithoutCapability() {
        assertInvalidArgument(
            validRequest()
                .toBuilder()
                .setMode(InstallMode.INSTALL_MODE_UPDATE)
                .setEnableRollback(true)
                .build(),
            emptySet(),
        )
    }

    @Test
    fun acceptsRollbackForUpdateWithCapability() {
        InstallRequestValidator.validate(
            validRequest()
                .toBuilder()
                .setMode(InstallMode.INSTALL_MODE_UPDATE)
                .setEnableRollback(true)
                .build(),
            setOf(ROLLBACK),
        )
    }

    @Test
    fun rejectsUpdateOwnershipWithoutCapability() {
        assertInvalidArgument(
            validRequest().toBuilder().setRequestUpdateOwnership(true).build(),
            emptySet(),
        )
    }

    @Test
    fun acceptsUpdateOwnershipWithCapability() {
        InstallRequestValidator.validate(
            validRequest().toBuilder().setRequestUpdateOwnership(true).build(),
            setOf(OWNERSHIP),
        )
    }

    @Test
    fun rejectsMalformedPackageNames() {
        listOf("", "example", ".com.example", "com..example", "com.example.", "com.example/evil")
            .forEach { packageName ->
                assertInvalidArgument(
                    validRequest().toBuilder().setExpectedPackage(packageName).build(),
                    emptySet(),
                )
            }
    }

    @Test
    fun rejectsNegativeVersionCodesAndUnspecifiedModes() {
        assertInvalidArgument(
            validRequest().toBuilder().setExpectedVersionCode(-1).build(),
            emptySet(),
        )
        assertInvalidArgument(
            validRequest().toBuilder().setMode(InstallMode.INSTALL_MODE_UNSPECIFIED).build(),
            emptySet(),
        )
    }

    @Test
    fun acceptsMissingHostSignerAndRejectsMalformedSignerDigests() {
        InstallRequestValidator.validate(
            validRequest().toBuilder().clearExpectedSignerSha256().build(),
            emptySet(),
        )
        assertInvalidArgument(
            validRequest()
                .toBuilder()
                .clearExpectedSignerSha256()
                .addExpectedSignerSha256(ByteString.copyFrom(ByteArray(31)))
                .build(),
            emptySet(),
        )
    }

    @Test
    fun rejectsMissingArtifactsAndUnsafeNames() {
        assertInvalidArgument(validRequest().toBuilder().clearArtifacts().build(), emptySet())
        assertInvalidArgument(
            validRequest()
                .toBuilder()
                .clearArtifacts()
                .addArtifacts(validArtifact().toBuilder().setName("../base").build())
                .build(),
            emptySet(),
        )
    }

    @Test
    fun rejectsDuplicateNamesInvalidSizesAndMalformedDigests() {
        val duplicate = validArtifact()
        assertInvalidArgument(
            validRequest().toBuilder().addArtifacts(duplicate).build(),
            emptySet(),
        )
        assertInvalidArgument(
            validRequest()
                .toBuilder()
                .clearArtifacts()
                .addArtifacts(validArtifact().toBuilder().setSize(0).build())
                .build(),
            emptySet(),
        )
        assertInvalidArgument(
            validRequest()
                .toBuilder()
                .clearArtifacts()
                .addArtifacts(
                    validArtifact()
                        .toBuilder()
                        .setSha256(ByteString.copyFrom(ByteArray(31)))
                        .build()
                )
                .build(),
            emptySet(),
        )
    }

    @Test
    fun rejectsInstallSetsOverTheMaximumSize() {
        val tooLarge =
            validRequest()
                .toBuilder()
                .clearArtifacts()
                .addArtifacts(
                    validArtifact()
                        .toBuilder()
                        .setSize(InstallRequestValidator.MAXIMUM_ARTIFACT_BYTES)
                        .build()
                )
                .addArtifacts(
                    validArtifact("split_config.arm64_v8a")
                        .toBuilder()
                        .setSize(InstallRequestValidator.MAXIMUM_ARTIFACT_BYTES)
                        .build()
                )
                .addArtifacts(
                    validArtifact("split_config.en")
                        .toBuilder()
                        .setSize(InstallRequestValidator.MAXIMUM_ARTIFACT_BYTES)
                        .build()
                )
                .addArtifacts(
                    validArtifact("split_config.xxhdpi")
                        .toBuilder()
                        .setSize(InstallRequestValidator.MAXIMUM_ARTIFACT_BYTES)
                        .build()
                )
                .addArtifacts(
                    validArtifact("split_extra")
                        .toBuilder()
                        .setSize(InstallRequestValidator.MAXIMUM_ARTIFACT_BYTES)
                        .build()
                )
                .build()

        assertInvalidArgument(tooLarge, emptySet())
    }

    private fun assertInvalidArgument(
        request: InstallRequest,
        capabilities: Set<String>,
    ) {
        try {
            InstallRequestValidator.validate(request, capabilities)
            throw AssertionError("expected INVALID_ARGUMENT")
        } catch (failure: StoreFailure) {
            assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, failure.code)
            assertTrue(failure.message.isNotBlank())
        }
    }

    private fun validRequest(): InstallRequest =
        InstallRequest.newBuilder()
            .setExpectedPackage("com.example.app")
            .setExpectedVersionCode(2)
            .addExpectedSignerSha256(ByteString.copyFrom(ByteArray(32) { 0x31 }))
            .setMode(InstallMode.INSTALL_MODE_INSTALL_NEW)
            .setInstallReason(4)
            .setPackageSource(1)
            .addArtifacts(validArtifact())
            .build()

    private fun validArtifact(name: String = "base"): ArtifactSpec =
        ArtifactSpec.newBuilder()
            .setName(name)
            .setSize(4)
            .setSha256(ByteString.copyFrom(ByteArray(32) { 0x32 }))
            .build()

    private companion object {
        const val OWNERSHIP = "store.ownership.v1"
        const val ROLLBACK = "store.rollback.v1"
    }
}
