package io.apkrun.guest.daemon

import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo as AndroidPackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import com.google.protobuf.ByteString
import com.google.protobuf.CodedOutputStream
import io.apkrun.guest.protocol.FrameCodec
import io.apkrun.guest.protocol.v1.GuestErrorCode
import io.apkrun.guest.protocol.v1.ListPackages
import io.apkrun.guest.protocol.v1.PackageFilter
import io.apkrun.guest.protocol.v1.PackageInfo as GuestPackageInfo
import io.apkrun.guest.protocol.v1.PackageList
import io.apkrun.guest.protocol.v1.PackageSummary
import io.apkrun.guest.protocol.v1.QueryPackage
import java.security.MessageDigest

private const val MAXIMUM_PACKAGE_STRING_BYTES = 64 * 1024
private const val MAXIMUM_PACKAGE_SIGNERS = 4_096
private const val MAXIMUM_PACKAGE_LIST_ITEMS = 4_096
private const val PACKAGE_LIST_ENVELOPE_HEADROOM = 1_024
private const val MAXIMUM_PACKAGE_LIST_BYTES =
    FrameCodec.MAXIMUM_BODY_SIZE - PACKAGE_LIST_ENVELOPE_HEADROOM

/** The package facts read from Android's PackageManager. */
data class GuestPackageFacts(
    val packageName: String,
    val versionCode: Long,
    val versionName: String,
    val label: String,
    val enabled: Boolean,
    val launchableComponent: String,
    val installerPackage: String,
    val firstInstallTimeMillis: Long,
    val lastUpdateTimeMillis: Long,
    val targetSdk: Int,
    val minSdk: Int,
    val signingSha256: List<ByteArray>,
    val launchable: Boolean,
    val userInstalled: Boolean,
)

/** The smaller set of package facts needed by a list response. */
data class GuestPackageSummaryFacts(
    val packageName: String,
    val label: String,
    val versionCode: Long,
    val launchable: Boolean,
    val userInstalled: Boolean,
)

/** Testable boundary around Android package inventory. */
interface PackageCatalog {
    /** Returns null only when Android does not have [packageName]. */
    fun find(packageName: String): GuestPackageFacts?

    /** Returns currently installed packages, including system packages. */
    fun listInstalled(): List<GuestPackageSummaryFacts>
}

/**
 * Reads the stock image's package inventory from Android's PackageManager.
 *
 * The Guest Agent runs with the shell uid in development mode, which can query the package list.
 * PackageManager remains the source of installed package identity and metadata.
 */
class AndroidPackageCatalog(private val packageManager: PackageManager) : PackageCatalog {
    override fun find(packageName: String): GuestPackageFacts? {
        val info =
            try {
                packageManager.getPackageInfo(packageName, packageInfoFlags())
            } catch (_: PackageManager.NameNotFoundException) {
                return null
            }
        return facts(info)
    }

    override fun listInstalled(): List<GuestPackageSummaryFacts> =
        packageManager.getInstalledPackages(PackageManager.PackageInfoFlags.of(0L)).mapNotNull {
            info ->
            val applicationInfo = info.applicationInfo ?: return@mapNotNull null
            val packageName = info.packageName ?: return@mapNotNull null
            GuestPackageSummaryFacts(
                packageName = packageName,
                label = loadLabel(applicationInfo, packageName),
                versionCode = info.longVersionCode,
                launchable = packageManager.getLaunchIntentForPackage(packageName) != null,
                userInstalled = applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM == 0,
            )
        }

    private fun facts(info: AndroidPackageInfo): GuestPackageFacts? {
        val applicationInfo = info.applicationInfo ?: return null
        val packageName = info.packageName ?: return null
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        return GuestPackageFacts(
            packageName = packageName,
            versionCode = info.longVersionCode,
            versionName = info.versionName.orEmpty(),
            label = loadLabel(applicationInfo, packageName),
            enabled = isEnabled(packageName, applicationInfo),
            launchableComponent = launchIntent?.component?.flattenToShortString().orEmpty(),
            installerPackage = installerPackage(packageName),
            firstInstallTimeMillis = info.firstInstallTime,
            lastUpdateTimeMillis = info.lastUpdateTime,
            targetSdk = applicationInfo.targetSdkVersion,
            minSdk = applicationInfo.minSdkVersion,
            signingSha256 = signingDigests(info),
            launchable = launchIntent != null,
            userInstalled = applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM == 0,
        )
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
            // The package can disappear between the inventory read and this query.
            applicationInfo.enabled
        }

    private fun installerPackage(packageName: String): String =
        try {
            packageManager.getInstallSourceInfo(packageName).installingPackageName.orEmpty()
        } catch (_: PackageManager.NameNotFoundException) {
            ""
        } catch (_: IllegalArgumentException) {
            ""
        }

    private fun signingDigests(info: AndroidPackageInfo): List<ByteArray> {
        val signers = info.signingInfo?.apkContentsSigners.orEmpty()
        return signers.map { signer -> sha256(signer) }.sortedWith(UNSIGNED_BYTES_COMPARATOR)
    }

    private fun sha256(signature: Signature): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())

    private fun packageInfoFlags(): PackageManager.PackageInfoFlags =
        PackageManager.PackageInfoFlags.of(PackageManager.GET_SIGNING_CERTIFICATES.toLong())

    companion object {
        private val UNSIGNED_BYTES_COMPARATOR =
            Comparator<ByteArray> { left, right ->
                for (index in 0 until minOf(left.size, right.size)) {
                    val result =
                        (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
                    if (result != 0) return@Comparator result
                }
                left.size.compareTo(right.size)
            }
    }
}

/** Implements the Guest Agent's `QueryPackage` and `ListPackages` operations. */
class PackageService(private val catalog: PackageCatalog) {
    /** Current version code for a package broadcast, or null if the package is already gone. */
    fun versionCode(packageName: String): Long? = catalog.find(packageName)?.versionCode

    fun query(request: QueryPackage): GuestPackageInfo {
        val packageName = request.getPackage()
        if (!PackageName.isValid(packageName)) {
            throw GuestFailure(
                GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                "the package name is not valid",
            )
        }
        val facts =
            catalog.find(packageName)
                ?: throw GuestFailure(
                    GuestErrorCode.GUEST_ERROR_CODE_NOT_FOUND,
                    "the package is not installed",
                    mapOf("package" to packageName),
                )
        validatePackageInfoStrings(facts)
        return GuestPackageInfo.newBuilder()
            .setPackage(facts.packageName)
            .setVersionCode(facts.versionCode)
            .setVersionName(facts.versionName)
            .setLabel(facts.label)
            .setEnabled(facts.enabled)
            .setLaunchableComponent(facts.launchableComponent)
            .setInstallerPackage(facts.installerPackage)
            .setFirstInstallTimeMs(facts.firstInstallTimeMillis)
            .setLastUpdateTimeMs(facts.lastUpdateTimeMillis)
            .setTargetSdk(facts.targetSdk)
            .setMinSdk(facts.minSdk)
            .addAllSigningSha256(facts.signingSha256.map(ByteString::copyFrom))
            .build()
    }

    fun list(request: ListPackages): PackageList {
        val filter =
            when (request.getFilter()) {
                PackageFilter.PACKAGE_FILTER_LAUNCHABLE -> Filter.LAUNCHABLE
                PackageFilter.PACKAGE_FILTER_USER_INSTALLED -> Filter.USER_INSTALLED
                PackageFilter.PACKAGE_FILTER_ALL -> Filter.ALL
                PackageFilter.PACKAGE_FILTER_UNSPECIFIED,
                PackageFilter.UNRECOGNIZED ->
                    throw GuestFailure(
                        GuestErrorCode.GUEST_ERROR_CODE_INVALID_ARGUMENT,
                        "the package filter is not supported",
                    )
            }
        val selected =
            catalog
                .listInstalled()
                .asSequence()
                // Framework entries such as the one-segment package "android" are not APKRun
                // package IDs.
                // They are omitted instead of poisoning the whole otherwise-valid inventory
                // response.
                .filter { PackageName.isValid(it.packageName) }
                .filter { filter.includes(it) }
                .sortedBy { it.packageName }
                .toList()
        if (selected.size > MAXIMUM_PACKAGE_LIST_ITEMS) {
            throw responseLimitExceeded()
        }

        val packages = PackageList.newBuilder()
        var serializedSize = 0
        for (facts in selected) {
            validatePackageSummaryStrings(facts)
            val packageSummary = summary(facts)
            serializedSize += CodedOutputStream.computeMessageSize(1, packageSummary)
            if (serializedSize > MAXIMUM_PACKAGE_LIST_BYTES) {
                throw responseLimitExceeded()
            }
            packages.addPackages(packageSummary)
        }
        return packages.build()
    }

    private fun validatePackageInfoStrings(facts: GuestPackageFacts) {
        if (facts.signingSha256.size > MAXIMUM_PACKAGE_SIGNERS) {
            throw responseLimitExceeded()
        }
        listOf(
                facts.packageName,
                facts.versionName,
                facts.label,
                facts.launchableComponent,
                facts.installerPackage,
            )
            .forEach(::validateString)
    }

    private fun validatePackageSummaryStrings(facts: GuestPackageSummaryFacts) {
        validateString(facts.packageName)
        validateString(facts.label)
    }

    private fun validateString(value: String) {
        if (value.toByteArray(Charsets.UTF_8).size > MAXIMUM_PACKAGE_STRING_BYTES) {
            throw responseLimitExceeded()
        }
    }

    private fun summary(facts: GuestPackageSummaryFacts): PackageSummary =
        PackageSummary.newBuilder()
            .setPackage(facts.packageName)
            .setLabel(facts.label)
            .setVersionCode(facts.versionCode)
            .setLaunchable(facts.launchable)
            .setUserInstalled(facts.userInstalled)
            .build()

    private fun responseLimitExceeded() =
        GuestFailure(
            GuestErrorCode.GUEST_ERROR_CODE_RESOURCE_EXHAUSTED,
            "package metadata exceeds the Guest Protocol response limit",
        )

    private enum class Filter {
        LAUNCHABLE,
        USER_INSTALLED,
        ALL;

        fun includes(facts: GuestPackageSummaryFacts): Boolean =
            when (this) {
                LAUNCHABLE -> facts.launchable
                USER_INSTALLED -> facts.userInstalled
                ALL -> true
            }
    }
}

/** The PackageID grammar shared by Guest Agent requests that name a package. */
internal object PackageName {
    private val SEGMENT = Regex("[A-Za-z][A-Za-z0-9_]*")

    fun isValid(value: String): Boolean {
        if (value.length > MAX_LENGTH) return false
        val segments = value.split('.')
        return segments.size >= 2 && segments.all(SEGMENT::matches)
    }

    private const val MAX_LENGTH = 255
}
