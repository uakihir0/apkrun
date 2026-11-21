import Foundation
import RuntimeAPI
import RuntimeClient

/// The daemon calls the home models use (host-ui.md §5.2).
///
/// `RuntimeControlClient` conforms for production; T0 tests inject a fake.
protocol RuntimeService: Sendable {
    func runtimeStatus() async throws -> RuntimeHostStatus
    func startRuntime() async throws -> RuntimeHostStatus
    func stopRuntime() async throws -> RuntimeHostStatus
    func restartRuntime() async throws -> RuntimeHostStatus
    func listPackages(filter: RuntimePackageFilter) async throws -> RuntimePackageListResult
    func listUpdates() async throws -> [PackageUpdateStatus]
    func updateHistory(packageID: RuntimePackageID?, limit: Int?) async throws -> [UpdateHistoryEntry]
    func listOperations() async throws -> [OperationSnapshot]
    func listSessions() async throws -> [WireSessionSummary]
    func listWrappers() async throws -> [WrapperListEntryWire]
    func packageIcon(packageID: RuntimePackageID) async throws -> Data?
    func launch(_ request: RuntimeLaunchRequest) async throws -> RuntimeLaunchResult
    func updatePackage(
        packageID: RuntimePackageID
    ) async throws -> (operation: OperationHandle, outcome: WireUpdateOutcome?)
    func checkForUpdates(
        packages: [RuntimePackageID]?
    ) async throws -> (operation: OperationHandle, results: [UpdateCheckResult])
    func adoptPackage(_ request: RuntimeAdoptPackageRequest) async throws -> RuntimePackageSummary
    func refreshWrapper(packageID: RuntimePackageID) async throws -> OperationHandle
    /// Regenerates a missing or modified wrapper (§5.3 row 6).
    func createWrapper(packageID: RuntimePackageID) async throws -> OperationHandle
    func repairPackage(packageID: RuntimePackageID) async throws -> OperationHandle
    func importPackage(
        _ request: RuntimeImportPackageRequest, files: [FileHandle]
    ) async throws -> RuntimeImportPreview
    /// The tracked install operation; the operation center shows it (§6.2).
    func beginInstallImported(
        _ request: RuntimeInstallImportedRequest, operationID: OperationID
    ) async throws -> OperationHandle
    func operationStatus(_ operationID: OperationID) async throws -> OperationSnapshot
    /// Creates a wrapper with the review sheet's name and location (§6.1).
    func createWrapper(_ request: WrapperRequest) async throws -> OperationHandle
    /// Finishes a wrapper generation the daemon could not place
    /// (wrapper.md §6.3); the client already moved the staged bundle.
    func placeStagedWrapper(
        stagingToken: String, finalURL: URL, bookmark: String?
    ) async throws -> WrapperInfo
    func discardImport(_ request: RuntimeDiscardImportRequest) async throws
    func subscribe(to topic: EventTopic) async throws -> AsyncStream<EventEnvelope>
    func packageInfo(packageID: RuntimePackageID) async throws -> RuntimePackageDetails
    func packageSettings(_ packageID: RuntimePackageID) async throws -> PackageSettingsWire?
    func updatePackageSettings(
        _ packageID: RuntimePackageID, patch: RuntimePackageSettingsPatch
    ) async throws -> PackageSettingsWire
    /// Global `settings.json` keys (configuration.md §2).
    func getConfig(keys: [String]?) async throws -> [String: String]
    func setConfig(key: String, value: String) async throws -> [String: String]
    func integrationStatus(packageID: RuntimePackageID) async throws -> IntegrationStatus
    func setUpdatePolicy(
        packageID: RuntimePackageID, policy: UpdatePolicy
    ) async throws -> PackageUpdateStatus
    func setUpdateAuthority(
        packageID: RuntimePackageID, authority: AuthorityChoice
    ) async throws -> PackageUpdateStatus
    func rollbackPackage(
        packageID: RuntimePackageID, allowDataLoss: Bool
    ) async throws -> RuntimeRollbackPackageControlReply
    func updateSkipped(
        packageID: RuntimePackageID, versionCode: RuntimeVersionCode, skipped: Bool
    ) async throws
    func beginUninstallPackage(
        _ request: RuntimeUninstallPackageRequest, operationID: OperationID
    ) async throws -> OperationHandle
    func removeWrapper(packageID: RuntimePackageID, trash: Bool) async throws -> Bool
    func deniedWrappers() async throws -> [DeniedWrapper]
    func clearWrapperDenial(bundleID: String, cdhash: String) async throws
}

extension RuntimeControlClient: RuntimeService {
    func updatePackage(
        packageID: RuntimePackageID
    ) async throws -> (operation: OperationHandle, outcome: WireUpdateOutcome?) {
        try await updatePackage(packageID: packageID, options: UpdateNowOptions(), files: [])
    }

    func checkForUpdates(
        packages: [RuntimePackageID]?
    ) async throws -> (operation: OperationHandle, results: [UpdateCheckResult]) {
        try await checkForUpdates(packages: packages, checkOnly: false)
    }

    func createWrapper(packageID: RuntimePackageID) async throws -> OperationHandle {
        try await createWrapper(
            WrapperRequest(packageID: packageID),
            icon: nil,
            operationID: OperationID()
        )
    }

    func createWrapper(_ request: WrapperRequest) async throws -> OperationHandle {
        try await createWrapper(request, icon: nil, operationID: OperationID())
    }

    func refreshWrapper(packageID: RuntimePackageID) async throws -> OperationHandle {
        try await refreshWrapper(
            packageID: packageID,
            change: WrapperRefreshWire(),
            icon: nil,
            operationID: OperationID()
        )
    }
}
