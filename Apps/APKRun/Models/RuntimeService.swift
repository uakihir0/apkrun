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
    func discardImport(_ request: RuntimeDiscardImportRequest) async throws
    func subscribe(to topic: EventTopic) async throws -> AsyncStream<EventEnvelope>
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

    func refreshWrapper(packageID: RuntimePackageID) async throws -> OperationHandle {
        try await refreshWrapper(
            packageID: packageID,
            change: WrapperRefreshWire(),
            icon: nil,
            operationID: OperationID()
        )
    }
}
