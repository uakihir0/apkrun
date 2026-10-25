package io.apkrun.store.store

import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import com.google.protobuf.ByteString
import io.apkrun.guest.protocol.v1.GetPackageMetadata
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ListManagedPackages
import io.apkrun.guest.protocol.v1.ManagedPackageFilter
import io.apkrun.guest.protocol.v1.SigningInfo
import io.apkrun.guest.protocol.v1.StorePackageInfo
import io.apkrun.guest.protocol.v1.StorePackageList
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

/** PackageManager facts used to construct the Store Agent's public metadata response. */
data class StorePackageFacts(
    val packageName: String,
    val versionCode: Long,
    val versionName: String,
    val label: String,
    val installerOfRecord: String,
    val updateOwner: String,
    val initiatingPackage: String,
    val firstInstallTimeMillis: Long,
    val lastUpdateTimeMillis: Long,
    val minSdk: Int,
    val targetSdk: Int,
    val splits: List<String>,
    val nativeAbis: List<String>,
    val currentSignerSha256: List<ByteArray>,
    val pastSignerSha256: List<ByteArray>,
    val signingSchemeVersion: Int,
    val enabled: Boolean,
    val suspended: Boolean,
    val requestedPermissionsCount: Int,
    val userInstalled: Boolean,
    val launchableComponent: String? = null,
)

/** Test seam around the Android package inventory. */
interface StorePackageCatalog {
    fun find(packageName: String): StorePackageFacts?

    fun listInstalled(): List<StorePackageFacts>
}

internal data class SigningDigestProjection(
    val current: List<ByteArray>,
    val past: List<ByteArray>,
)

/** Keeps the current signer set deterministic and the certificate history in rotation order. */
internal fun projectSigningDigests(
    currentSignerSha256: List<ByteArray>,
    certificateHistorySha256: List<ByteArray>?,
): SigningDigestProjection {
    val current = currentSignerSha256.sortedWith(SIGNING_DIGEST_BYTE_ORDER)
    val past =
        certificateHistorySha256.orEmpty().filterNot { historicalDigest ->
            currentSignerSha256.any { currentDigest ->
                currentDigest.contentEquals(historicalDigest)
            }
        }
    return SigningDigestProjection(current = current, past = past)
}

/** Reads the authoritative installed package metadata from PackageManager. */
class AndroidStorePackageCatalog(private val packageManager: PackageManager) : StorePackageCatalog {
    override fun find(packageName: String): StorePackageFacts? {
        val info =
            try {
                packageManager.getPackageInfo(packageName, packageInfoFlags())
            } catch (_: PackageManager.NameNotFoundException) {
                return null
            }
        return facts(info)
    }

    override fun listInstalled(): List<StorePackageFacts> =
        packageManager.getInstalledPackages(packageInfoFlags()).mapNotNull(::facts)

    private fun facts(info: PackageInfo): StorePackageFacts? {
        val applicationInfo = info.applicationInfo ?: return null
        val packageName = info.packageName ?: return null
        val installSource =
            try {
                packageManager.getInstallSourceInfo(packageName)
            } catch (_: PackageManager.NameNotFoundException) {
                null
            } catch (_: IllegalArgumentException) {
                null
            }
        val signing = info.signingInfo
        val signingDigests =
            projectSigningDigests(
                currentSignerSha256 = signing?.apkContentsSigners.orEmpty().map(::sha256),
                certificateHistorySha256 = signing?.signingCertificateHistory?.map(::sha256),
            )
        return StorePackageFacts(
            packageName = packageName,
            versionCode = info.longVersionCode,
            versionName = info.versionName.orEmpty(),
            label = loadLabel(applicationInfo, packageName),
            installerOfRecord = installSource?.installingPackageName.orEmpty(),
            updateOwner = installSource?.updateOwnerPackageName.orEmpty(),
            initiatingPackage = installSource?.initiatingPackageName.orEmpty(),
            firstInstallTimeMillis = info.firstInstallTime,
            lastUpdateTimeMillis = info.lastUpdateTime,
            minSdk = applicationInfo.minSdkVersion,
            targetSdk = applicationInfo.targetSdkVersion,
            splits = (listOf("base") + info.splitNames.orEmpty()).distinct(),
            nativeAbis = readNativeAbis(applicationInfo.sourceDir, applicationInfo.splitSourceDirs),
            currentSignerSha256 = signingDigests.current,
            pastSignerSha256 = signingDigests.past,
            signingSchemeVersion = signing?.schemeVersion ?: 0,
            enabled = isEnabled(packageName, applicationInfo),
            suspended = applicationInfo.flags and ApplicationInfo.FLAG_SUSPENDED != 0,
            requestedPermissionsCount = info.requestedPermissions?.size ?: 0,
            userInstalled = applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM == 0,
            launchableComponent =
                packageManager.getLaunchIntentForPackage(packageName)?.component?.flattenToString(),
        )
    }

    private fun packageInfoFlags(): PackageManager.PackageInfoFlags {
        val flags =
            (PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_PERMISSIONS).toLong()
        return PackageManager.PackageInfoFlags.of(flags)
    }

    private fun loadLabel(applicationInfo: ApplicationInfo, packageName: String): String =
        try {
            applicationInfo.loadLabel(packageManager).toString().ifEmpty { packageName }
        } catch (_: RuntimeException) {
            packageName
        }

    private fun isEnabled(packageName: String, applicationInfo: ApplicationInfo): Boolean =
        try {
            when (packageManager.getApplicationEnabledSetting(packageName)) {
                PackageManager.COMPONENT_ENABLED_STATE_ENABLED -> true
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED_USER,
                PackageManager.COMPONENT_ENABLED_STATE_DISABLED_UNTIL_USED -> false
                PackageManager.COMPONENT_ENABLED_STATE_DEFAULT -> applicationInfo.enabled
                else -> applicationInfo.enabled
            }
        } catch (_: IllegalArgumentException) {
            applicationInfo.enabled
        }

    private fun readNativeAbis(base: String?, splits: Array<String>?): List<String> {
        val files = listOfNotNull(base) + splits.orEmpty()
        return files
            .asSequence()
            .flatMap { path ->
                runCatching {
                        ZipFile(path).use { archive ->
                            archive
                                .entries()
                                .asSequence()
                                .mapNotNull { entry ->
                                    if (!entry.isDirectory && entry.name.startsWith("lib/")) {
                                        entry.name.split('/').getOrNull(1)
                                    } else {
                                        null
                                    }
                                }
                                .toList()
                        }
                    }
                    .getOrDefault(emptyList())
                    .asSequence()
            }
            .distinct()
            .sorted()
            .toList()
    }

    private fun sha256(signature: Signature): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
}

private val SIGNING_DIGEST_BYTE_ORDER =
    Comparator<ByteArray> { left, right ->
        for (index in 0 until minOf(left.size, right.size)) {
            val result = (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
            if (result != 0) return@Comparator result
        }
        left.size.compareTo(right.size)
    }

/** Implements `GetPackageMetadata` and `ListManagedPackages` using Android's PackageManager. */
class MetadataService(private val catalog: StorePackageCatalog) {
    fun get(request: GetPackageMetadata): StorePackageInfo {
        val packageName = request.getPackage()
        validatePackageName(packageName)
        val facts =
            catalog.find(packageName)
                ?: throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "the package is not installed",
                    mapOf("package" to packageName),
                )
        return toProto(facts)
    }

    fun list(request: ListManagedPackages): StorePackageList {
        val filter =
            when (request.filter) {
                ManagedPackageFilter.MANAGED_PACKAGE_FILTER_MANAGED_BY_APKRUN -> {
                    { facts: StorePackageFacts ->
                        facts.userInstalled && facts.installerOfRecord == STORE_PACKAGE
                    }
                }
                ManagedPackageFilter.MANAGED_PACKAGE_FILTER_ALL_USER_INSTALLED -> {
                    { facts: StorePackageFacts -> facts.userInstalled }
                }
                ManagedPackageFilter.MANAGED_PACKAGE_FILTER_UNSPECIFIED,
                ManagedPackageFilter.UNRECOGNIZED ->
                    throw StoreFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "the managed package filter is not supported",
                    )
            }
        val packages =
            catalog
                .listInstalled()
                .asSequence()
                .filter { PackageName.isValid(it.packageName) }
                .filter(filter)
                .sortedBy(StorePackageFacts::packageName)
                .toList()
        if (packages.size > MAXIMUM_PACKAGE_COUNT) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_RESOURCE_EXHAUSTED,
                "the installed package list is too large",
            )
        }
        val result = StorePackageList.newBuilder()
        packages.forEach { result.addPackages(toProto(it)) }
        return result.build()
    }

    private fun validatePackageName(packageName: String) {
        if (!PackageName.isValid(packageName)) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "package is not a valid Android package name",
            )
        }
    }

    private fun toProto(facts: StorePackageFacts): StorePackageInfo =
        StorePackageInfo.newBuilder()
            .setPackage(facts.packageName)
            .setVersionCode(facts.versionCode)
            .setVersionName(facts.versionName)
            .setLabel(facts.label)
            .setInstallerOfRecord(facts.installerOfRecord)
            .setUpdateOwner(facts.updateOwner)
            .setInitiatingPackage(facts.initiatingPackage)
            .setFirstInstallTimeMs(facts.firstInstallTimeMillis)
            .setLastUpdateTimeMs(facts.lastUpdateTimeMillis)
            .setMinSdk(facts.minSdk)
            .setTargetSdk(facts.targetSdk)
            .addAllSplits(facts.splits)
            .addAllNativeAbis(facts.nativeAbis)
            .setSigning(
                SigningInfo.newBuilder()
                    .addAllCurrentSha256(facts.currentSignerSha256.map(ByteString::copyFrom))
                    .addAllPastSha256(facts.pastSignerSha256.map(ByteString::copyFrom))
                    .setSchemeVersion(facts.signingSchemeVersion)
            )
            .setEnabled(facts.enabled)
            .setSuspended(facts.suspended)
            .setRequestedPermissionsCount(facts.requestedPermissionsCount)
            .setLaunchableComponent(facts.launchableComponent.orEmpty())
            .build()

    private companion object {
        const val STORE_PACKAGE = "io.apkrun.store"
        const val MAXIMUM_PACKAGE_COUNT = 4_096
    }
}

/** Facts parsed from one staged APK archive by Android's package parser. */
data class ArchiveFacts(
    val packageName: String,
    val versionCode: Long,
    val versionName: String,
    val splitName: String,
    val nativeAbis: List<String>,
    val minSdk: Int,
    val targetSdk: Int,
    val signerSha256: List<ByteArray>,
    val signingSchemeVersion: Int,
)

fun interface ArchiveReader {
    fun read(file: File): ArchiveFacts?
}

/** Android's parser is used for previews and for the final pre-commit identity check. */
class AndroidArchiveReader(private val packageManager: PackageManager) : ArchiveReader {
    override fun read(file: File): ArchiveFacts? {
        if (!file.isFile) return null
        val info =
            packageManager.getPackageArchiveInfo(
                file.path,
                PackageManager.PackageInfoFlags.of(
                    PackageManager.GET_SIGNING_CERTIFICATES.toLong()
                ),
            ) ?: return null
        val applicationInfo = info.applicationInfo ?: return null
        applicationInfo.sourceDir = file.path
        applicationInfo.publicSourceDir = file.path
        return ArchiveFacts(
            packageName = info.packageName.orEmpty(),
            versionCode = info.longVersionCode,
            versionName = info.versionName.orEmpty(),
            splitName = info.splitNames?.singleOrNull() ?: "base",
            nativeAbis = readNativeAbis(file),
            minSdk = applicationInfo.minSdkVersion,
            targetSdk = applicationInfo.targetSdkVersion,
            signerSha256 =
                info.signingInfo
                    ?.apkContentsSigners
                    .orEmpty()
                    .map { signer ->
                        MessageDigest.getInstance("SHA-256").digest(signer.toByteArray())
                    }
                    .sortedWith(byteOrder),
            signingSchemeVersion = info.signingInfo?.schemeVersion ?: 0,
        )
    }

    private fun readNativeAbis(file: File): List<String> = runCatching {
        ZipFile(file).use { archive ->
            archive
                .entries()
                .asSequence()
                .mapNotNull { entry ->
                    if (!entry.isDirectory && entry.name.startsWith("lib/")) {
                        entry.name.split('/').getOrNull(1)
                    } else {
                        null
                    }
                }
                .distinct()
                .sorted()
                .toList()
        }
    }
        .getOrDefault(emptyList())

    private companion object {
        val byteOrder =
            Comparator<ByteArray> { left, right ->
                for (index in 0 until minOf(left.size, right.size)) {
                    val comparison =
                        (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
                    if (comparison != 0) return@Comparator comparison
                }
                left.size.compareTo(right.size)
            }
    }
}

/** Parses a full staged APK set and rejects missing, duplicate, or mismatched splits. */
class ArchiveInspector(private val reader: ArchiveReader) {
    fun inspect(files: List<File>): io.apkrun.guest.protocol.v1.ArchiveInfo {
        if (files.isEmpty()) invalidArchive()
        val facts = files.map { file ->
            reader.read(file)
                ?: throw StoreFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                    "an install artifact is not a valid APK",
                )
        }
        val base = facts.singleOrNull { it.splitName == "base" } ?: invalidArchive()
        if (facts.map(ArchiveFacts::splitName).distinct().size != facts.size) invalidArchive()
        if (
            facts.any {
                it.packageName != base.packageName ||
                    it.versionCode != base.versionCode ||
                    (it.signerSha256.isNotEmpty() &&
                        !sameDigests(it.signerSha256, base.signerSha256))
            }
        ) {
            throw StoreFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the install artifacts do not form one package version and signer set",
            )
        }
        return io.apkrun.guest.protocol.v1.ArchiveInfo.newBuilder()
            .setPackage(base.packageName)
            .setVersionCode(base.versionCode)
            .setVersionName(base.versionName)
            .addAllSplitNames(facts.map(ArchiveFacts::splitName).sorted())
            .addAllNativeAbis(facts.flatMap(ArchiveFacts::nativeAbis).distinct().sorted())
            .setMinSdk(base.minSdk)
            .setTargetSdk(base.targetSdk)
            .addAllSignerSha256(base.signerSha256.map(ByteString::copyFrom))
            .setSigningSchemeVersion(base.signingSchemeVersion)
            .build()
    }

    private fun invalidArchive(): Nothing =
        throw StoreFailure(
            GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
            "the install artifact set must contain exactly one base APK and unique splits",
        )

    private fun sameDigests(left: List<ByteArray>, right: List<ByteArray>): Boolean =
        left.size == right.size &&
            left.sortedWith(DIGEST_ORDER).zip(right.sortedWith(DIGEST_ORDER)).all { (a, b) ->
                a.contentEquals(b)
            }

    private companion object {
        val DIGEST_ORDER =
            Comparator<ByteArray> { left, right ->
                for (index in 0 until minOf(left.size, right.size)) {
                    val comparison =
                        (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
                    if (comparison != 0) return@Comparator comparison
                }
                left.size.compareTo(right.size)
            }
    }
}
