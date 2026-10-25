package io.apkrun.store.store

import android.content.Context
import io.apkrun.guest.protocol.v1.AbandonInstall
import io.apkrun.guest.protocol.v1.ArchiveInfo
import io.apkrun.guest.protocol.v1.BeginInstallResult
import io.apkrun.guest.protocol.v1.CommitInstall
import io.apkrun.guest.protocol.v1.GetPackageMetadata
import io.apkrun.guest.protocol.v1.InspectArchive
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.ListManagedPackages
import io.apkrun.guest.protocol.v1.StorePackageInfo
import io.apkrun.guest.protocol.v1.StorePackageList
import io.apkrun.guest.protocol.v1.Uninstall
import io.apkrun.guest.protocol.v1.UninstallResult

/**
 * Connects the wire operations to PackageInstaller, the Android archive parser, and PackageManager.
 */
class AndroidStoreOperations(
    private val context: Context,
    private val installService: InstallService,
    private val uninstallService: UninstallService,
    private val metadataService: MetadataService,
    private val transfers: ArtifactTransferService,
) : StoreOperations {
    override fun inspectArchive(request: InspectArchive): ArchiveInfo = transfers.inspect(request)

    override fun beginInstall(
        request: InstallRequest,
        enabledCapabilities: Set<String>,
        controlSessionId: String,
    ): BeginInstallResult =
        installService.beginInstall(request, enabledCapabilities, controlSessionId)

    override fun commitInstall(request: CommitInstall, controlSessionId: String) =
        installService.commitInstall(request, controlSessionId)

    override fun abandonInstall(request: AbandonInstall, controlSessionId: String) =
        installService.abandonInstall(request, controlSessionId)

    override fun uninstall(request: Uninstall): UninstallResult =
        uninstallService.uninstall(request)

    override fun getPackageMetadata(request: GetPackageMetadata): StorePackageInfo =
        metadataService.get(request)

    override fun listManagedPackages(request: ListManagedPackages): StorePackageList =
        metadataService.list(request)
}
