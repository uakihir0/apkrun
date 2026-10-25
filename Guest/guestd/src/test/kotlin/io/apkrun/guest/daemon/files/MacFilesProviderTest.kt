package io.apkrun.guest.daemon.files

import android.content.pm.ProviderInfo
import android.database.Cursor
import android.provider.DocumentsContract.Document
import io.apkrun.guest.protocol.v1.AccessLevel
import io.apkrun.guest.protocol.v1.PackageAccess
import io.apkrun.guest.protocol.v1.SetSharedFolderAccess
import io.apkrun.guest.protocol.v1.SharedRoot
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class MacFilesProviderTest {
    private lateinit var provider: MacFilesProvider
    private lateinit var host: FakeHostClient

    @Before
    fun setUp() {
        MacFilesProviderServices.resetForTests()
        provider = MacFilesProvider()
        provider.attachInfo(
            RuntimeEnvironment.getApplication(),
            ProviderInfo().apply {
                authority = MAC_FILES_AUTHORITY
                exported = true
                grantUriPermissions = true
                readPermission = "android.permission.MANAGE_DOCUMENTS"
                writePermission = "android.permission.MANAGE_DOCUMENTS"
            },
        )
        host = FakeHostClient()
        MacFilesProviderServices.installHostClient(host)
        check(
            MacFilesProviderServices.replaceAccess(
                SetSharedFolderAccess.newBuilder()
                    .addRoots(
                        SharedRoot.newBuilder()
                            .setRootId(ROOT_ID)
                            .setTitle("Shared")
                            .setMaxAccess(AccessLevel.ACCESS_LEVEL_READ_WRITE)
                    )
                    .addAccess(
                        PackageAccess.newBuilder()
                            .setPackage(ALLOWED_PACKAGE)
                            .setAccess(AccessLevel.ACCESS_LEVEL_READ_ONLY)
                    )
                    .build()
            )
        )
    }

    @After
    fun tearDown() {
        if (::provider.isInitialized) provider.shutdown()
        MacFilesProviderServices.resetForTests()
    }

    @Test
    fun pickerCanBrowseNamesWithoutExposingFileContents() {
        Shadows.shadowOf(provider).setCallingPackage(DOCUMENTS_UI_PACKAGE)

        val cursor =
            provider.queryChildDocuments(
                parentDocumentId = "$ROOT_ID:",
                projection = null,
                sortOrder = null,
            )
        try {
            assertEquals(1, cursor.count)
            assertTrue(cursor.moveToFirst())
            assertEquals("notes.txt", cursor.string(Document.COLUMN_DISPLAY_NAME))
            assertEquals("text/plain", cursor.string(Document.COLUMN_MIME_TYPE))
        } finally {
            cursor.close()
        }

        assertEquals(DOCUMENTS_UI_PACKAGE, host.lastPackage)
        assertEquals(0, host.openCount)
    }

    @Test
    fun anUnlistedPackageCannotOpenAReadableDocumentId() {
        Shadows.shadowOf(provider).setCallingPackage("io.example.other")

        assertThrows(SecurityException::class.java) {
            provider.openDocument("$ROOT_ID:notes.txt", "r", null)
        }

        assertEquals(0, host.openCount)
    }

    @Test
    fun anAllowedPackageStillNeedsTheUriGrantBeforeOpeningContent() {
        Shadows.shadowOf(provider).setCallingPackage(ALLOWED_PACKAGE)

        assertThrows(SecurityException::class.java) {
            provider.openDocument("$ROOT_ID:notes.txt", "r", null)
        }

        assertEquals(0, host.openCount)
    }

    @Test
    fun pickerCannotCreateInAReadOnlyRoot() {
        MacFilesProviderServices.replaceAccess(
            SetSharedFolderAccess.newBuilder()
                .addRoots(
                    SharedRoot.newBuilder()
                        .setRootId(ROOT_ID)
                        .setTitle("Shared")
                        .setMaxAccess(AccessLevel.ACCESS_LEVEL_READ_ONLY)
                )
                .addAccess(
                    PackageAccess.newBuilder()
                        .setPackage(ALLOWED_PACKAGE)
                        .setAccess(AccessLevel.ACCESS_LEVEL_READ_WRITE)
                )
                .build()
        )
        Shadows.shadowOf(provider).setCallingPackage(DOCUMENTS_UI_PACKAGE)

        assertThrows(SecurityException::class.java) {
            provider.createDocument("$ROOT_ID:", "text/plain", "new.txt")
        }

        assertEquals(0, host.createCount)
    }

    @Test
    fun staleConnectionCannotClearTheReplacementHostClient() {
        val stale = host
        val replacement = FakeHostClient()
        MacFilesProviderServices.installHostClient(replacement)

        MacFilesProviderServices.clearHostClient(stale)

        assertSame(replacement, MacFilesProviderServices.hostClient())
        MacFilesProviderServices.clearHostClient(replacement)
        assertThrows(IllegalStateException::class.java) {
            MacFilesProviderServices.hostClient()
        }
    }

    @Test
    fun defaultReadAheadStopsAtEndOfFile() {
        val ranges = host.readRanges(handle = 1, firstOffset = 0, rangeCount = 4)

        assertEquals(1, ranges.size)
        assertEquals("hello", ranges.single().decodeToString())
    }

    private fun Cursor.string(column: String): String {
        val index = getColumnIndexOrThrow(column)
        return getString(index)
    }

    private class FakeHostClient : MacFilesHostClient {
        var lastPackage: String? = null
        var openCount = 0
        var createCount = 0

        override fun listRoots(packageName: String): List<MacFilesRoot> {
            lastPackage = packageName
            return listOf(
                MacFilesRoot(
                    rootId = ROOT_ID,
                    title = "Shared",
                    access = AccessLevel.ACCESS_LEVEL_READ_WRITE,
                    available = true,
                    bytesFree = 1024,
                )
            )
        }

        override fun queryChildren(
            packageName: String,
            rootId: String,
            path: String,
            pageToken: String,
        ): MacFilesPage {
            lastPackage = packageName
            return MacFilesPage(
                listOf(
                    fileDocument(),
                    fileDocument(".hidden"),
                    fileDocument("outside.txt").copy(path = "outside/outside.txt"),
                ),
                "",
            )
        }

        override fun stat(packageName: String, rootId: String, path: String): MacFilesDocument {
            lastPackage = packageName
            return fileDocument()
        }

        override fun openFile(
            packageName: String,
            rootId: String,
            path: String,
            mode: AccessLevelForOpen,
        ): MacFilesOpenFile {
            lastPackage = packageName
            openCount += 1
            return MacFilesOpenFile(handle = 1, size = 5)
        }

        override fun readRange(handle: Long, offset: Long, length: Int): ByteArray =
            "hello".toByteArray().copyOfRange(offset.toInt(), minOf(offset.toInt() + length, 5))

        override fun writeRange(handle: Long, offset: Long, data: ByteArray) = Unit

        override fun closeFile(handle: Long, fsync: Boolean) = Unit

        override fun createDocument(
            packageName: String,
            rootId: String,
            parentPath: String,
            name: String,
            isDirectory: Boolean,
        ): MacFilesDocument {
            lastPackage = packageName
            createCount += 1
            return MacFilesDocument(name, name, isDirectory, 0, 0, "text/plain")
        }

        override fun deleteDocument(packageName: String, rootId: String, path: String) = Unit

        override fun renameDocument(
            packageName: String,
            rootId: String,
            path: String,
            newName: String,
        ): MacFilesDocument = fileDocument(newName)

        private fun fileDocument(name: String = "notes.txt") =
            MacFilesDocument(
                path = name,
                name = name,
                isDirectory = false,
                size = 5,
                modifiedAtMillis = 1,
                mimeType = "text/plain",
            )
    }

    private companion object {
        const val ROOT_ID = "shared"
        const val ALLOWED_PACKAGE = "io.example.reader"
        const val DOCUMENTS_UI_PACKAGE = "com.android.documentsui"
    }
}
