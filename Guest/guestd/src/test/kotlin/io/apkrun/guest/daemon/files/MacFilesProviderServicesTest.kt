package io.apkrun.guest.daemon.files

import io.apkrun.guest.protocol.v1.AccessLevel
import io.apkrun.guest.protocol.v1.PackageAccess
import io.apkrun.guest.protocol.v1.SetSharedFolderAccess
import io.apkrun.guest.protocol.v1.SharedRoot
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MacFilesProviderServicesTest {
    @Test
    fun effectiveAccessIsTheLowerOfPackageAndRootAccess() {
        val policy =
            MacFilesAccessSnapshot.from(
                accessRequest(
                    roots =
                        listOf(
                            root("read-write", AccessLevel.ACCESS_LEVEL_READ_WRITE),
                            root("read-only", AccessLevel.ACCESS_LEVEL_READ_ONLY),
                        ),
                    packages =
                        listOf(
                            packageAccess("io.example.editor", AccessLevel.ACCESS_LEVEL_READ_WRITE),
                            packageAccess("io.example.reader", AccessLevel.ACCESS_LEVEL_READ_ONLY),
                        ),
                )
            )!!

        assertTrue(policy.canRead("io.example.editor", "read-write"))
        assertTrue(policy.canWrite("io.example.editor", "read-write"))
        assertTrue(policy.canRead("io.example.editor", "read-only"))
        assertFalse(policy.canWrite("io.example.editor", "read-only"))
        assertTrue(policy.canRead("io.example.reader", "read-write"))
        assertFalse(policy.canWrite("io.example.reader", "read-write"))
    }

    @Test
    fun unlistedPackagesAndRootsHaveNoAccess() {
        val policy =
            MacFilesAccessSnapshot.from(
                accessRequest(
                    roots = listOf(root("shared", AccessLevel.ACCESS_LEVEL_READ_WRITE)),
                    packages =
                        listOf(
                            packageAccess("io.example.editor", AccessLevel.ACCESS_LEVEL_READ_WRITE)
                        ),
                )
            )!!

        assertFalse(policy.canRead("io.example.other", "shared"))
        assertFalse(policy.canRead("io.example.editor", "not-shared"))
        assertFalse(policy.canWrite("io.example.other", "shared"))
    }

    @Test
    fun malformedReplacementClearsPreviouslyGrantedAccess() {
        MacFilesProviderServices.resetForTests()
        assertTrue(
            MacFilesProviderServices.replaceAccess(
                accessRequest(
                    roots = listOf(root("shared", AccessLevel.ACCESS_LEVEL_READ_WRITE)),
                    packages =
                        listOf(
                            packageAccess("io.example.editor", AccessLevel.ACCESS_LEVEL_READ_WRITE)
                        ),
                )
            )
        )
        val malformed =
            accessRequest(
                roots = listOf(root("../outside", AccessLevel.ACCESS_LEVEL_READ_WRITE)),
                packages =
                    listOf(packageAccess("io.example.editor", AccessLevel.ACCESS_LEVEL_READ_WRITE)),
            )

        assertFalse(MacFilesProviderServices.replaceAccess(malformed))
        assertFalse(MacFilesProviderServices.access().canRead("io.example.editor", "shared"))
        assertNull(MacFilesProviderServices.access().root("../outside"))
    }

    @Test
    fun rejectsUnsafeAndDuplicatePackageEntries() {
        assertNull(
            MacFilesAccessSnapshot.from(
                accessRequest(
                    roots = listOf(root("shared", AccessLevel.ACCESS_LEVEL_READ_WRITE)),
                    packages =
                        listOf(
                            packageAccess("io.example.editor", AccessLevel.ACCESS_LEVEL_READ_WRITE),
                            packageAccess("io.example.editor", AccessLevel.ACCESS_LEVEL_READ_ONLY),
                        ),
                )
            )
        )
        assertNull(
            MacFilesAccessSnapshot.from(
                accessRequest(
                    roots = listOf(root("shared", AccessLevel.ACCESS_LEVEL_READ_WRITE)),
                    packages =
                        listOf(packageAccess("../editor", AccessLevel.ACCESS_LEVEL_READ_WRITE)),
                )
            )
        )
    }

    @Test
    fun rejectsUnspecifiedAccessAndDuplicateRootIds() {
        assertNull(
            MacFilesAccessSnapshot.from(
                accessRequest(
                    roots = listOf(root("shared", AccessLevel.ACCESS_LEVEL_UNSPECIFIED)),
                    packages =
                        listOf(
                            packageAccess("io.example.editor", AccessLevel.ACCESS_LEVEL_READ_WRITE)
                        ),
                )
            )
        )
        assertNull(
            MacFilesAccessSnapshot.from(
                accessRequest(
                    roots =
                        listOf(
                            root("shared", AccessLevel.ACCESS_LEVEL_READ_WRITE),
                            root("shared", AccessLevel.ACCESS_LEVEL_READ_ONLY),
                        ),
                    packages =
                        listOf(
                            packageAccess("io.example.editor", AccessLevel.ACCESS_LEVEL_READ_WRITE)
                        ),
                )
            )
        )
    }

    private fun accessRequest(
        roots: List<SharedRoot>,
        packages: List<PackageAccess>,
    ): SetSharedFolderAccess =
        SetSharedFolderAccess.newBuilder().addAllRoots(roots).addAllAccess(packages).build()

    private fun root(id: String, access: AccessLevel): SharedRoot =
        SharedRoot.newBuilder().setRootId(id).setTitle("Shared files").setMaxAccess(access).build()

    private fun packageAccess(name: String, access: AccessLevel): PackageAccess =
        PackageAccess.newBuilder().setPackage(name).setAccess(access).build()
}
