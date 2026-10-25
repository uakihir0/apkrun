package io.apkrun.store.store

import io.apkrun.guest.protocol.v1.AbandonInstall
import io.apkrun.guest.protocol.v1.ArchiveInfo
import io.apkrun.guest.protocol.v1.BeginInstallResult
import io.apkrun.guest.protocol.v1.CommitInstall
import io.apkrun.guest.protocol.v1.GetPackageMetadata
import io.apkrun.guest.protocol.v1.InstallRequest
import io.apkrun.guest.protocol.v1.ListManagedPackages
import io.apkrun.guest.protocol.v1.StorePackageInfo
import io.apkrun.guest.protocol.v1.StorePackageList
import io.apkrun.guest.protocol.v1.Uninstall
import io.apkrun.guest.protocol.v1.UninstallResult

/** Android-independent boundary for the seven Store Agent operations in this task. */
interface StoreOperations {
    fun inspectArchive(request: io.apkrun.guest.protocol.v1.InspectArchive): ArchiveInfo

    fun beginInstall(
        request: InstallRequest,
        enabledCapabilities: Set<String>,
        controlSessionId: String,
    ): BeginInstallResult

    fun commitInstall(request: CommitInstall, controlSessionId: String)

    fun abandonInstall(request: AbandonInstall, controlSessionId: String)

    fun uninstall(request: Uninstall): UninstallResult

    fun getPackageMetadata(request: GetPackageMetadata): StorePackageInfo

    fun listManagedPackages(request: ListManagedPackages): StorePackageList
}
