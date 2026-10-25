package io.apkrun.guest.daemon.files

import io.apkrun.guest.protocol.v1.AccessLevel
import io.apkrun.guest.protocol.v1.SetSharedFolderAccess
import java.util.concurrent.atomic.AtomicReference

const val MAC_FILES_AUTHORITY = "io.apkrun.guest.macfiles"
const val MAXIMUM_HOST_FILE_RANGE_BYTES = 1024 * 1024
const val MAXIMUM_READ_AHEAD_RANGES = 4

/**
 * Host operations used by [MacFilesProvider]. The transport owns request multiplexing and limits.
 */
interface MacFilesHostClient {
    fun listRoots(packageName: String): List<MacFilesRoot>

    fun queryChildren(
        packageName: String,
        rootId: String,
        path: String,
        pageToken: String,
    ): MacFilesPage

    fun stat(packageName: String, rootId: String, path: String): MacFilesDocument

    fun openFile(
        packageName: String,
        rootId: String,
        path: String,
        mode: AccessLevelForOpen,
    ): MacFilesOpenFile

    fun readRange(handle: Long, offset: Long, length: Int): ByteArray

    /**
     * Reads adjacent, bounded ranges for sequential descriptor access. A transport may override
     * this to pipeline requests; the default keeps test and simple clients correct.
     */
    fun readRanges(handle: Long, firstOffset: Long, rangeCount: Int): List<ByteArray> {
        require(firstOffset >= 0L)
        require(rangeCount in 1..MAXIMUM_READ_AHEAD_RANGES)
        require(firstOffset <= Long.MAX_VALUE - (rangeCount - 1L) * MAXIMUM_HOST_FILE_RANGE_BYTES)
        val ranges = ArrayList<ByteArray>(rangeCount)
        for (index in 0 until rangeCount) {
            val bytes =
                readRange(
                    handle,
                    firstOffset + index * MAXIMUM_HOST_FILE_RANGE_BYTES,
                    MAXIMUM_HOST_FILE_RANGE_BYTES,
                )
            ranges += bytes
            if (bytes.size < MAXIMUM_HOST_FILE_RANGE_BYTES) break
        }
        return ranges
    }

    fun writeRange(handle: Long, offset: Long, data: ByteArray)

    fun closeFile(handle: Long, fsync: Boolean)

    fun createDocument(
        packageName: String,
        rootId: String,
        parentPath: String,
        name: String,
        isDirectory: Boolean,
    ): MacFilesDocument

    fun deleteDocument(packageName: String, rootId: String, path: String)

    fun renameDocument(
        packageName: String,
        rootId: String,
        path: String,
        newName: String,
    ): MacFilesDocument
}

/** A validated host root, returned by HostListRoots. */
data class MacFilesRoot(
    val rootId: String,
    val title: String,
    val access: AccessLevel,
    val available: Boolean,
    val bytesFree: Long,
)

/** A validated HostQueryChildren response page. */
data class MacFilesPage(val entries: List<MacFilesDocument>, val nextPageToken: String)

/** A validated HostStat or document mutation result. Paths are relative to [rootId]. */
data class MacFilesDocument(
    val path: String,
    val name: String,
    val isDirectory: Boolean,
    val size: Long,
    val modifiedAtMillis: Long,
    val mimeType: String,
)

/** A host-owned handle returned by HostOpenFile. */
data class MacFilesOpenFile(val handle: Long, val size: Long)

/** The four access modes defined by Guest Protocol §7.5. */
enum class AccessLevelForOpen {
    READ,
    WRITE,
    READ_WRITE,
    TRUNCATE,
}

/** A root's configured maximum access, before per-package access is applied. */
data class MacFilesRootPolicy(
    val rootId: String,
    val title: String,
    val maxAccess: AccessLevel,
)

/** An immutable copy of SetSharedFolderAccess, used only for guest-side early rejection. */
data class MacFilesAccessSnapshot(
    val roots: Map<String, MacFilesRootPolicy>,
    val packages: Map<String, Map<String, AccessLevel>>,
) {
    fun root(rootId: String): MacFilesRootPolicy? = roots[rootId]

    fun hasReadablePackage(rootId: String): Boolean =
        packages.values.any { accessFor(it[rootId], roots[rootId]?.maxAccess) != null }

    fun hasWritablePackage(rootId: String): Boolean =
        packages.values.any {
            accessFor(it[rootId], roots[rootId]?.maxAccess) == AccessLevel.ACCESS_LEVEL_READ_WRITE
        }

    fun canRead(packageName: String, rootId: String): Boolean =
        accessFor(packages[packageName]?.get(rootId), roots[rootId]?.maxAccess) != null

    fun canWrite(packageName: String, rootId: String): Boolean =
        accessFor(packages[packageName]?.get(rootId), roots[rootId]?.maxAccess) ==
            AccessLevel.ACCESS_LEVEL_READ_WRITE

    companion object {
        val EMPTY = MacFilesAccessSnapshot(emptyMap(), emptyMap())

        /**
         * Copies and validates the host policy message. A malformed or incomplete policy is
         * rejected before it can grant a document URI.
         */
        fun from(request: SetSharedFolderAccess): MacFilesAccessSnapshot? {
            if (
                request.rootsCount > MAXIMUM_ROOTS ||
                    request.accessCount > MAXIMUM_PACKAGE_ACCESS_ENTRIES
            ) {
                return null
            }

            val roots = LinkedHashMap<String, MacFilesRootPolicy>(request.rootsCount)
            for (root in request.rootsList) {
                if (
                    !validRootId(root.rootId) ||
                        root.title.isBlank() ||
                        root.title.length > MAXIMUM_TITLE_LENGTH ||
                        root.maxAccess !in READ_ACCESS_LEVELS ||
                        roots.containsKey(root.rootId)
                ) {
                    return null
                }
                roots[root.rootId] = MacFilesRootPolicy(root.rootId, root.title, root.maxAccess)
            }

            val packages = LinkedHashMap<String, MutableMap<String, AccessLevel>>()
            for (entry in request.accessList) {
                if (
                    !validPackageName(entry.getPackage()) ||
                        entry.access !in READ_ACCESS_LEVELS ||
                        entry.getPackage() in packages
                ) {
                    return null
                }
                packages[entry.getPackage()] =
                    LinkedHashMap<String, AccessLevel>(roots.size).apply {
                        // The wire message assigns one access level per package. The provider
                        // applies each root's maximum below.
                        roots.keys.forEach { rootId -> put(rootId, entry.access) }
                    }
            }
            return MacFilesAccessSnapshot(roots, packages)
        }

        private fun accessFor(
            packageAccess: AccessLevel?,
            rootAccess: AccessLevel?,
        ): AccessLevel? {
            if (packageAccess !in READ_ACCESS_LEVELS || rootAccess !in READ_ACCESS_LEVELS) {
                return null
            }
            return if (
                packageAccess == AccessLevel.ACCESS_LEVEL_READ_WRITE &&
                    rootAccess == AccessLevel.ACCESS_LEVEL_READ_WRITE
            ) {
                AccessLevel.ACCESS_LEVEL_READ_WRITE
            } else {
                AccessLevel.ACCESS_LEVEL_READ_ONLY
            }
        }

        private fun validRootId(value: String): Boolean =
            value.isNotBlank() &&
                value.length <= MAXIMUM_ROOT_ID_LENGTH &&
                value.all { it.isLetterOrDigit() || it == '_' || it == '-' }

        private fun validPackageName(value: String): Boolean {
            if (value.isBlank() || value.length > MAXIMUM_PACKAGE_LENGTH) return false
            val segments = value.split('.')
            return segments.size >= 2 &&
                segments.all { segment ->
                    segment.isNotEmpty() &&
                        segment.first().isAsciiLetter() &&
                        segment.all {
                            it.isAsciiLetter() || it.isAsciiDigit() || it == '_'
                        }
                }
        }

        private fun Char.isAsciiLetter(): Boolean = this in 'A'..'Z' || this in 'a'..'z'

        private fun Char.isAsciiDigit(): Boolean = this in '0'..'9'

        private val READ_ACCESS_LEVELS =
            setOf(AccessLevel.ACCESS_LEVEL_READ_ONLY, AccessLevel.ACCESS_LEVEL_READ_WRITE)
        private const val MAXIMUM_ROOTS = 33 // the built-in root plus up to 32 user roots
        private const val MAXIMUM_ROOT_ID_LENGTH = 128
        private const val MAXIMUM_TITLE_LENGTH = 255
        private const val MAXIMUM_PACKAGE_LENGTH = 255
        private const val MAXIMUM_PACKAGE_ACCESS_ENTRIES = 4096
    }
}

/**
 * Process-wide provider dependencies. The custom image injects the Guest Agent's bulk-channel
 * client; ordinary development-shell agents never expose this provider.
 */
object MacFilesProviderServices {
    private val accessSnapshot = AtomicReference(MacFilesAccessSnapshot.EMPTY)
    private val client = AtomicReference<MacFilesHostClient?>()

    fun installHostClient(hostClient: MacFilesHostClient) {
        client.set(hostClient)
        notifyRootsChanged()
    }

    fun clearHostClient() {
        client.set(null)
        notifyRootsChanged()
    }

    fun clearHostClient(expected: MacFilesHostClient) {
        if (client.compareAndSet(expected, null)) {
            notifyRootsChanged()
        }
    }

    fun hostClient(): MacFilesHostClient =
        client.get() ?: throw IllegalStateException("Mac folder access is unavailable")

    fun hasHostClient(): Boolean = client.get() != null

    fun replaceAccess(request: SetSharedFolderAccess): Boolean {
        val next =
            MacFilesAccessSnapshot.from(request)
                ?: run {
                    accessSnapshot.set(MacFilesAccessSnapshot.EMPTY)
                    return false
                }
        accessSnapshot.set(next)
        return true
    }

    fun access(): MacFilesAccessSnapshot = accessSnapshot.get()

    internal fun resetForTests() {
        accessSnapshot.set(MacFilesAccessSnapshot.EMPTY)
        client.set(null)
    }

    private fun notifyRootsChanged() {
        runCatching {
            val uri = android.provider.DocumentsContract.buildRootsUri(MAC_FILES_AUTHORITY)
            io.apkrun.guest.runtime.SystemContext.get().contentResolver.notifyChange(uri, null)
        }
    }
}
