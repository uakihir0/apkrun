package io.apkrun.store

import io.apkrun.guest.protocol.v1.BeginInstallResult
import io.apkrun.guest.protocol.v1.CheckInstallConstraints
import io.apkrun.guest.protocol.v1.ConstraintsResult
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.ListManagedPackages
import io.apkrun.guest.protocol.v1.Pong
import io.apkrun.guest.protocol.v1.RollbackPackage
import io.apkrun.guest.protocol.v1.RollbackResult
import io.apkrun.guest.protocol.v1.StorePackageInfo
import io.apkrun.guest.protocol.v1.StorePackageList
import io.apkrun.guest.protocol.v1.Uninstall
import io.apkrun.guest.protocol.v1.UninstallResult

/**
 * The operations of the Store Agent that [StoreDispatcher] calls (guest-protocol.md §11). The
 * services implement it on the device; tests implement it with fakes. A failure is thrown as a
 * [io.apkrun.guest.protocol.GuestFailure], or as the exception of the framework call.
 */
interface StoreOperations {
    fun ping(): Pong = Pong.getDefaultInstance()

    /** Opens an install session and returns its IDs (store.install.v1). */
    fun beginInstall(request: InstallRequest): BeginInstallResult

    /** Verifies and commits the install session (store.install.v1). */
    fun commitInstall(installId: String)

    /** Abandons the install session (store.install.v1). */
    fun abandonInstall(installId: String)

    /** Removes a package through PackageInstaller (store.metadata.v1). */
    fun uninstall(request: Uninstall): UninstallResult

    /** Returns the store metadata of one package, or null when absent (store.metadata.v1). */
    fun getPackageMetadata(packageName: String): StorePackageInfo?

    /** Lists packages under the store's filter (store.metadata.v1). */
    fun listManagedPackages(request: ListManagedPackages): StorePackageList

    /** Releases Android update ownership (store.ownership.v1). */
    fun relinquishUpdateOwnership(packageName: String)

    /**
     * Commits a RollbackManager rollback matching the package and both versions
     * (store.rollback.v1). `NOT_AVAILABLE` is a result, not a failure.
     */
    fun rollbackPackage(request: RollbackPackage): RollbackResult

    /**
     * Answers whether Android's install constraints hold now (store.constraints.v1). A hint only.
     */
    suspend fun checkInstallConstraints(request: CheckInstallConstraints): ConstraintsResult
}

/** The device implementation of [StoreOperations]: the services of [StoreDaemon]. */
class DeviceStoreOperations(
    private val install: InstallService,
    private val ownership: OwnershipService,
    private val metadata: MetadataService,
    private val rollback: RollbackService,
    private val constraints: ConstraintsService,
) : StoreOperations {
    override fun beginInstall(request: InstallRequest): BeginInstallResult =
        install.beginInstall(request)

    override fun commitInstall(installId: String) = install.commitInstall(installId)

    override fun abandonInstall(installId: String) = install.abandonInstall(installId)

    override fun uninstall(request: Uninstall): UninstallResult =
        install.uninstall(request.`package`, request.keepData)

    override fun getPackageMetadata(packageName: String): StorePackageInfo? =
        metadata.packageInfo(packageName)

    override fun listManagedPackages(request: ListManagedPackages): StorePackageList =
        metadata.listManaged(request)

    override fun relinquishUpdateOwnership(packageName: String) =
        ownership.relinquishUpdateOwnership(packageName)

    override fun rollbackPackage(request: RollbackPackage): RollbackResult =
        rollback.rollbackPackage(
            request.`package`,
            request.fromVersionCode,
            request.toVersionCode,
        )

    override suspend fun checkInstallConstraints(
        request: CheckInstallConstraints
    ): ConstraintsResult = constraints.checkInstallConstraints(request)
}
