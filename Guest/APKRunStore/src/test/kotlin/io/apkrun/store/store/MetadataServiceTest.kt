package io.apkrun.store.store

import io.apkrun.guest.protocol.v1.GetPackageMetadata
import io.apkrun.guest.protocol.v1.ListManagedPackages
import io.apkrun.guest.protocol.v1.ManagedPackageFilter
import org.junit.Assert.assertEquals
import org.junit.Test

class MetadataServiceTest {
    @Test
    fun unrotatedSigningHistoryExcludesTheCurrentSigner() {
        val projection =
            projectSigningDigests(
                currentSignerSha256 = listOf(digest(1)),
                certificateHistorySha256 = listOf(digest(1)),
            )

        assertEquals(listOf(1), digestIds(projection.current))
        assertEquals(emptyList<Int>(), digestIds(projection.past))
    }

    @Test
    fun rotatedSigningHistoryPreservesOldestToNewestOrderAndExcludesCurrentSigner() {
        val projection =
            projectSigningDigests(
                currentSignerSha256 = listOf(digest(3)),
                certificateHistorySha256 = listOf(digest(1), digest(2), digest(3)),
            )

        assertEquals(listOf(3), digestIds(projection.current))
        assertEquals(listOf(1, 2), digestIds(projection.past))
    }

    @Test
    fun coSignedPackagesExcludeEveryCurrentSignerAndSupportMissingHistory() {
        val currentSigners = listOf(digest(4), digest(2))
        val projection =
            projectSigningDigests(
                currentSignerSha256 = currentSigners,
                certificateHistorySha256 = listOf(digest(4), digest(2)),
            )
        val missingHistory =
            projectSigningDigests(
                currentSignerSha256 = currentSigners,
                certificateHistorySha256 = null,
            )

        assertEquals(listOf(2, 4), digestIds(projection.current))
        assertEquals(emptyList<Int>(), digestIds(projection.past))
        assertEquals(listOf(2, 4), digestIds(missingHistory.current))
        assertEquals(emptyList<Int>(), digestIds(missingHistory.past))
    }

    @Test
    fun metadataAndPackageListsCarryPackageManagerLauncherComponent() {
        val facts =
            packageFacts("io.apkrun.fixture.hellotext", "io.apkrun.fixture.hellotext/.MainActivity")
        val service = MetadataService(FixtureCatalog(facts))

        val metadata =
            service.get(GetPackageMetadata.newBuilder().setPackage(facts.packageName).build())
        assertEquals("io.apkrun.fixture.hellotext/.MainActivity", metadata.launchableComponent)

        val packages =
            service.list(
                ListManagedPackages.newBuilder()
                    .setFilter(ManagedPackageFilter.MANAGED_PACKAGE_FILTER_ALL_USER_INSTALLED)
                    .build()
            )
        assertEquals(1, packages.packagesCount)
        assertEquals(
            "io.apkrun.fixture.hellotext/.MainActivity",
            packages.getPackages(0).launchableComponent,
        )
    }

    @Test
    fun packagesWithoutLauncherActivitiesReportAnEmptyComponent() {
        val facts = packageFacts("io.apkrun.fixture.background", null)
        val service = MetadataService(FixtureCatalog(facts))

        val metadata =
            service.get(GetPackageMetadata.newBuilder().setPackage(facts.packageName).build())

        assertEquals("", metadata.launchableComponent)
    }

    private fun packageFacts(packageName: String, launchableComponent: String?) =
        StorePackageFacts(
            packageName = packageName,
            versionCode = 1,
            versionName = "1.0",
            label = packageName,
            installerOfRecord = "io.apkrun.store",
            updateOwner = "",
            initiatingPackage = "",
            firstInstallTimeMillis = 1,
            lastUpdateTimeMillis = 1,
            minSdk = 23,
            targetSdk = 37,
            splits = listOf("base"),
            nativeAbis = listOf("arm64-v8a"),
            currentSignerSha256 = listOf(ByteArray(32) { 1 }),
            pastSignerSha256 = emptyList(),
            signingSchemeVersion = 3,
            enabled = true,
            suspended = false,
            requestedPermissionsCount = 0,
            userInstalled = true,
            launchableComponent = launchableComponent,
        )

    private fun digest(value: Int) = ByteArray(32) { value.toByte() }

    private fun digestIds(digests: List<ByteArray>) = digests.map { it.first().toInt() }

    private class FixtureCatalog(private val facts: StorePackageFacts) : StorePackageCatalog {
        override fun find(packageName: String): StorePackageFacts? = facts.takeIf {
            it.packageName == packageName
        }

        override fun listInstalled(): List<StorePackageFacts> = listOf(facts)
    }
}
