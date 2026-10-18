package io.apkrun.guest.daemon

import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ListPackages
import io.apkrun.guest.protocol.v1.PackageFilter
import io.apkrun.guest.protocol.v1.QueryPackage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PackageServiceTest {
    @Test
    fun queryReturnsThePackageManagerFacts() {
        val service = PackageService(FakePackageCatalog(listOf(fixturePackage())))

        val result =
            service.query(
                QueryPackage.newBuilder().setPackage("io.apkrun.fixture.hellotext").build()
            )

        assertEquals("io.apkrun.fixture.hellotext", result.getPackage())
        assertEquals(37L, result.getVersionCode())
        assertEquals("2.4.1", result.getVersionName())
        assertEquals("Hello Text", result.getLabel())
        assertTrue(result.getEnabled())
        assertEquals("io.apkrun.fixture.hellotext/.MainActivity", result.getLaunchableComponent())
        assertEquals("io.apkrun.store", result.getInstallerPackage())
        assertEquals(123L, result.getFirstInstallTimeMs())
        assertEquals(456L, result.getLastUpdateTimeMs())
        assertEquals(35, result.getTargetSdk())
        assertEquals(23, result.getMinSdk())
        assertEquals(
            listOf(ByteString.copyFrom(ByteArray(32) { 0xAB.toByte() })),
            result.getSigningSha256List(),
        )
    }

    @Test
    fun absentPackageReturnsNotFound() {
        val service = PackageService(FakePackageCatalog(emptyList()))
        var failure: GuestFailure? = null

        try {
            service.query(QueryPackage.newBuilder().setPackage("io.example.missing").build())
        } catch (error: GuestFailure) {
            failure = error
        }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND, failure?.code)
        assertEquals("io.example.missing", failure?.detail?.get("package"))
    }

    @Test
    fun oversizedPackageMetadataIsRejectedBeforeBuildingAResponse() {
        val facts = fixturePackage(label = "x".repeat(64 * 1024 + 1))
        val service = PackageService(FakePackageCatalog(listOf(facts)))
        val failure =
            try {
                service.query(QueryPackage.newBuilder().setPackage(facts.packageName).build())
                null
            } catch (error: GuestFailure) {
                error
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_RESOURCE_EXHAUSTED, failure?.code)
    }

    @Test
    fun queryRejectsInvalidPackageNamesBeforeCallingPackageManager() {
        val catalog = FakePackageCatalog(listOf(fixturePackage()))
        val service = PackageService(catalog)
        val invalidNames = listOf("", "hello", ".io.app", "io..app", "io._app", "io.apр")

        invalidNames.forEach { name ->
            val error =
                try {
                    service.query(QueryPackage.newBuilder().setPackage(name).build())
                    null
                } catch (failure: GuestFailure) {
                    failure
                }
            assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, error?.code)
        }

        assertEquals(0, catalog.findCalls)
    }

    @Test
    fun listFiltersAndSortsPackageSummaries() {
        val catalog =
            FakePackageCatalog(
                listOf(
                    fixturePackage(
                        packageName = "io.example.zapp",
                        launchable = false,
                        userInstalled = true,
                    ),
                    fixturePackage(
                        packageName = "io.example.system",
                        launchable = true,
                        userInstalled = false,
                    ),
                    fixturePackage(
                        packageName = "io.example.app",
                        launchable = true,
                        userInstalled = true,
                    ),
                )
            )
        val service = PackageService(catalog)

        val launchable =
            service.list(
                ListPackages.newBuilder().setFilter(PackageFilter.PACKAGE_FILTER_LAUNCHABLE).build()
            )
        val userInstalled =
            service.list(
                ListPackages.newBuilder()
                    .setFilter(PackageFilter.PACKAGE_FILTER_USER_INSTALLED)
                    .build()
            )
        val all =
            service.list(
                ListPackages.newBuilder().setFilter(PackageFilter.PACKAGE_FILTER_ALL).build()
            )

        assertEquals(
            listOf("io.example.app", "io.example.system"),
            launchable.getPackagesList().map { it.getPackage() },
        )
        assertTrue(launchable.getPackagesList().all { it.getLaunchable() })
        assertEquals(
            listOf("io.example.app", "io.example.zapp"),
            userInstalled.getPackagesList().map { it.getPackage() },
        )
        assertTrue(userInstalled.getPackagesList().all { it.getUserInstalled() })
        assertEquals(
            listOf("io.example.app", "io.example.system", "io.example.zapp"),
            all.getPackagesList().map { it.getPackage() },
        )
        assertFalse(
            all.getPackagesList()
                .first { it.getPackage() == "io.example.system" }
                .getUserInstalled()
        )
        assertEquals(3, catalog.listCalls)
    }

    @Test
    fun listSkipsFrameworkEntriesThatAreNotValidAndroidPackageIds() {
        val catalog =
            FakePackageCatalog(
                listOf(
                    fixturePackage(packageName = "android"),
                    fixturePackage(packageName = "io.example.app"),
                )
            )
        val service = PackageService(catalog)

        val all =
            service.list(
                ListPackages.newBuilder().setFilter(PackageFilter.PACKAGE_FILTER_ALL).build()
            )

        assertEquals(listOf("io.example.app"), all.getPackagesList().map { it.getPackage() })
    }

    @Test
    fun queryRejectsOversizedSignerListsBeforeBuildingAResponse() {
        val facts = fixturePackage(signingSha256 = List(4_097) { ByteArray(32) })
        val service = PackageService(FakePackageCatalog(listOf(facts)))

        val failure =
            try {
                service.query(QueryPackage.newBuilder().setPackage(facts.packageName).build())
                null
            } catch (error: GuestFailure) {
                error
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_RESOURCE_EXHAUSTED, failure?.code)
    }

    @Test
    fun listRejectsUnspecifiedOrUnknownFiltersBeforeCallingPackageManager() {
        val catalog = FakePackageCatalog(emptyList())
        val service = PackageService(catalog)
        val error =
            try {
                service.list(
                    ListPackages.newBuilder()
                        .setFilter(PackageFilter.PACKAGE_FILTER_UNSPECIFIED)
                        .build()
                )
                null
            } catch (failure: GuestFailure) {
                failure
            }

        assertEquals(GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT, error?.code)
        assertEquals(0, catalog.listCalls)
    }

    @Test
    fun packageNamesUseAsciiAndroidGrammarAndLengthLimit() {
        assertTrue(PackageName.isValid("io.apkrun.fixture_2.app"))
        assertTrue(PackageName.isValid("a.${"b".repeat(253)}"))
        assertFalse(PackageName.isValid("io._apkrun.app"))
        assertFalse(PackageName.isValid("io.apkrun.hellø"))
        assertFalse(PackageName.isValid("a.${"b".repeat(254)}"))
    }

    private fun fixturePackage(
        packageName: String = "io.apkrun.fixture.hellotext",
        launchable: Boolean = true,
        userInstalled: Boolean = true,
        label: String = "Hello Text",
        signingSha256: List<ByteArray> = listOf(ByteArray(32) { 0xAB.toByte() }),
    ): GuestPackageFacts =
        GuestPackageFacts(
            packageName = packageName,
            versionCode = 37,
            versionName = "2.4.1",
            label = label,
            enabled = true,
            launchableComponent = if (launchable) "$packageName/.MainActivity" else "",
            installerPackage = "io.apkrun.store",
            firstInstallTimeMillis = 123,
            lastUpdateTimeMillis = 456,
            targetSdk = 35,
            minSdk = 23,
            signingSha256 = signingSha256,
            launchable = launchable,
            userInstalled = userInstalled,
        )

    private class FakePackageCatalog(packages: List<GuestPackageFacts>) : PackageCatalog {
        private val packagesByName = packages.associateBy { it.packageName }
        var findCalls = 0
        var listCalls = 0

        override fun find(packageName: String): GuestPackageFacts? {
            findCalls += 1
            return packagesByName[packageName]
        }

        override fun listInstalled(): List<GuestPackageSummaryFacts> {
            listCalls += 1
            return packagesByName.values.map {
                GuestPackageSummaryFacts(
                    packageName = it.packageName,
                    label = it.label,
                    versionCode = it.versionCode,
                    launchable = it.launchable,
                    userInstalled = it.userInstalled,
                )
            }
        }
    }
}
