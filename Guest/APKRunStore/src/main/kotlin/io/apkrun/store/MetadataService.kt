package io.apkrun.store

import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import io.apkrun.guest.protocol.v1.ListManagedPackages
import io.apkrun.guest.protocol.v1.ManagedPackageFilter
import io.apkrun.guest.protocol.v1.SigningInfo
import io.apkrun.guest.protocol.v1.StorePackageInfo
import io.apkrun.guest.protocol.v1.StorePackageList
import java.security.MessageDigest

/**
 * GetPackageMetadata and ListManagedPackages of the Store Agent (store.metadata.v1,
 * guest-protocol.md §11.4). `update_owner` is Android's
 * `InstallSourceInfo.getUpdateOwnerPackageName()` (API 34), which the store records after every
 * install (package-store.md §6.3).
 */
class MetadataService(
    private val packageManager: PackageManager,
    private val agentPackage: String,
) {
    /** The store metadata of one package, or null when absent. */
    fun packageInfo(packageName: String): StorePackageInfo? {
        val flags = METADATA_FLAGS
        val info =
            try {
                packageManager.getPackageInfo(packageName, flags)
            } catch (notFound: PackageManager.NameNotFoundException) {
                return null
            }
        return toWire(info)
    }

    /** The packages of the filter (§11.4): managed by APKRun, or every user-installed package. */
    fun listManaged(request: ListManagedPackages): StorePackageList {
        val packages =
            packageManager.getInstalledPackages(METADATA_FLAGS).filter { info ->
                when (request.filter) {
                    ManagedPackageFilter.MANAGED_PACKAGE_FILTER_MANAGED_BY_APKRUN ->
                        updateOwner(info) == agentPackage
                    ManagedPackageFilter.MANAGED_PACKAGE_FILTER_ALL_USER_INSTALLED ->
                        (info.applicationInfo?.flags ?: 0) and ApplicationInfo.FLAG_SYSTEM == 0
                    else -> false
                }
            }
        return StorePackageList.newBuilder().addAllPackages(packages.map { toWire(it) }).build()
    }

    private fun toWire(info: PackageInfo): StorePackageInfo {
        val builder =
            StorePackageInfo.newBuilder()
                .setPackage(info.packageName)
                .setVersionCode(info.longVersionCode)
                .setVersionName(info.versionName.orEmpty())
                .setLabel(info.applicationInfo?.loadLabel(packageManager)?.toString().orEmpty())
                .setFirstInstallTimeMs(info.firstInstallTime)
                .setLastUpdateTimeMs(info.lastUpdateTime)
                .setMinSdk(info.applicationInfo?.minSdkVersion ?: 0)
                .setTargetSdk(info.applicationInfo?.targetSdkVersion ?: 0)
                .setEnabled(info.applicationInfo?.enabled ?: false)
                .setSuspended(
                    try {
                        packageManager.isPackageSuspended(info.packageName)
                    } catch (error: Exception) {
                        false
                    }
                )
                .setRequestedPermissionsCount(info.requestedPermissions?.size ?: 0)
        info.applicationInfo?.let { appInfo ->
            builder
                .addAllSplits(
                    appInfo.splitSourceDirs?.map { it.substringAfterLast('/') } ?: emptyList()
                )
                // primaryCpuAbi and secondaryCpuAbi are hidden in the compileSdk stub.
                .addAllNativeAbis(
                    listOfNotNull(
                        io.apkrun.guest.runtime.HiddenApi.read(appInfo, "primaryCpuAbi") as? String,
                        io.apkrun.guest.runtime.HiddenApi.read(appInfo, "secondaryCpuAbi")
                            as? String,
                    )
                )
        }
        installSource(info.packageName)?.let { source ->
            builder
                .setInstallerOfRecord(source.installingPackageName.orEmpty())
                .setUpdateOwner(source.updateOwnerPackageName.orEmpty())
                .setInitiatingPackage(source.initiatingPackageName.orEmpty())
        }
        info.signingInfo?.let { signing ->
            builder.signing =
                SigningInfo.newBuilder()
                    .addAllCurrentSha256(
                        signing.apkContentsSigners?.map {
                            com.google.protobuf.ByteString.copyFrom(it.toByteArray().sha256())
                        } ?: emptyList()
                    )
                    .addAllPastSha256(
                        signing.signingCertificateHistory?.map {
                            com.google.protobuf.ByteString.copyFrom(it.toByteArray().sha256())
                        } ?: emptyList()
                    )
                    .setSchemeVersion(0)
                    .build()
        }
        return builder.build()
    }

    private fun updateOwner(info: PackageInfo): String? =
        installSource(info.packageName)?.updateOwnerPackageName

    private fun installSource(packageName: String) = runCatching {
        packageManager.getInstallSourceInfo(packageName)
    }
        .getOrNull()

    private fun ByteArray.sha256(): ByteArray = MessageDigest.getInstance("SHA-256").digest(this)

    companion object {
        private val METADATA_FLAGS =
            PackageManager.PackageInfoFlags.of(
                (PackageManager.GET_SIGNING_CERTIFICATES or PackageManager.GET_PERMISSIONS).toLong()
            )
    }
}
