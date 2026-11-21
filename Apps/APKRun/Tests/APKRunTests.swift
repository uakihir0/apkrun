import Foundation
import RuntimeAPI
import XCTest

/// A `RuntimeService` stub driven by the tests.
final class FakeRuntimeService: RuntimeService, @unchecked Sendable {
    var packages: [RuntimePackageSummary] = []
    var updates: [PackageUpdateStatus] = []
    var history: [UpdateHistoryEntry] = []
    var sessions: [WireSessionSummary] = []
    var wrappers: [WrapperListEntryWire] = []
    var operations: [OperationSnapshot] = []
    var icons: [RuntimePackageID: Data] = [:]
    var error: (any Error)?
    var callCounts: [String: Int] = [:]

    private let lock = NSLock()

    private func count(_ name: String) {
        lock.lock()
        callCounts[name, default: 0] += 1
        lock.unlock()
    }

    private func record(_ body: () -> Void) {
        lock.lock()
        body()
        lock.unlock()
    }

    func runtimeStatus() async throws -> RuntimeHostStatus {
        count("runtimeStatus")
        if let error { throw error }
        return RuntimeHostStatus(
            hostState: "running", runtimeState: "ready", bootProgress: nil,
            startupFailureStep: nil, startupFailureCode: nil,
            crashLoopActive: false, daemonPID: 1, imageVersion: nil)
    }

    func startRuntime() async throws -> RuntimeHostStatus { try await runtimeStatus() }
    func stopRuntime() async throws -> RuntimeHostStatus { try await runtimeStatus() }
    func restartRuntime() async throws -> RuntimeHostStatus { try await runtimeStatus() }

    func listPackages(filter: RuntimePackageFilter) async throws -> RuntimePackageListResult {
        count("listPackages")
        if let error { throw error }
        return RuntimePackageListResult(packages: packages, source: .cachedAndroid)
    }

    func listUpdates() async throws -> [PackageUpdateStatus] {
        count("listUpdates")
        if let error { throw error }
        return updates
    }

    func updateHistory(packageID: RuntimePackageID?, limit: Int?) async throws -> [UpdateHistoryEntry] {
        count("updateHistory")
        return history
    }

    func listOperations() async throws -> [OperationSnapshot] {
        count("listOperations")
        return operations
    }

    func listSessions() async throws -> [WireSessionSummary] {
        count("listSessions")
        if let error { throw error }
        return sessions
    }

    func listWrappers() async throws -> [WrapperListEntryWire] {
        count("listWrappers")
        if let error { throw error }
        return wrappers
    }

    func packageIcon(packageID: RuntimePackageID) async throws -> Data? {
        count("packageIcon")
        return icons[packageID]
    }

    func launch(_ request: RuntimeLaunchRequest) async throws -> RuntimeLaunchResult {
        count("launch")
        return RuntimeLaunchResult(
            sessionID: UUID(), packageID: request.packageID, state: .running)
    }

    func updatePackage(packageID: RuntimePackageID)
        async throws -> (operation: OperationHandle, outcome: WireUpdateOutcome?)
    {
        count("updatePackage")
        return (OperationHandle(operationID: OperationID(), kind: .update), nil)
    }

    func checkForUpdates(packages: [RuntimePackageID]?)
        async throws -> (operation: OperationHandle, results: [UpdateCheckResult])
    {
        count("checkForUpdates")
        return (OperationHandle(operationID: OperationID(), kind: .updateCheck), [])
    }

    func adoptPackage(_ request: RuntimeAdoptPackageRequest) async throws -> RuntimePackageSummary {
        count("adoptPackage")
        return RuntimePackageSummary(
            packageID: request.packageID, displayName: "Adopted", versionCode: nil,
            versionName: nil, state: .installed, managed: true, updateAuthority: .apkrun)
    }

    func createWrapper(packageID: RuntimePackageID) async throws -> OperationHandle {
        count("createWrapper")
        return OperationHandle(operationID: OperationID(), kind: .wrapperCreate)
    }

    func refreshWrapper(packageID: RuntimePackageID) async throws -> OperationHandle {
        count("refreshWrapper")
        return OperationHandle(operationID: OperationID(), kind: .wrapperRefresh)
    }

    var refreshChange: WrapperRefreshWire?
    var refreshIcon: FileHandle?
    func refreshWrapper(
        packageID: RuntimePackageID,
        change: WrapperRefreshWire,
        iconFile: FileHandle?
    ) async throws -> OperationHandle {
        record {
            refreshChange = change
            refreshIcon = iconFile
        }
        return try await refreshWrapper(packageID: packageID)
    }

    func repairPackage(packageID: RuntimePackageID) async throws -> OperationHandle {
        count("repairPackage")
        return OperationHandle(operationID: OperationID(), kind: .repair)
    }

    var previewToReturn: RuntimeImportPreview?

    func importPackage(_ request: RuntimeImportPackageRequest, files: [FileHandle])
        async throws -> RuntimeImportPreview
    {
        count("importPackage")
        if let previewToReturn { return previewToReturn }
        throw RuntimeWireError(domain: "package", code: "refused", message: "stub")
    }

    func beginInstallImported(
        _ request: RuntimeInstallImportedRequest, operationID: OperationID
    ) async throws -> OperationHandle {
        count("installImported")
        installRequests.append(request)
        return OperationHandle(operationID: operationID, kind: .install)
    }

    func operationStatus(_ operationID: OperationID) async throws -> OperationSnapshot {
        count("operationStatus")
        return OperationSnapshot(
            operationID: operationID, kind: .install, startedAt: Date(),
            result: .succeeded(
                .package(
                    RuntimePackageSummary(
                        packageID: RuntimePackageID(rawValue: "com.example.a")!,
                        displayName: "Example", versionCode: 1, versionName: "1.0",
                        state: .installed, managed: true, updateAuthority: .apkrun))))
    }

    func createWrapper(_ request: WrapperRequest) async throws -> OperationHandle {
        count("createWrapper")
        wrapperRequests.append(request)
        return OperationHandle(operationID: OperationID(), kind: .wrapperCreate)
    }

    var installRequests: [RuntimeInstallImportedRequest] = []
    var wrapperRequests: [WrapperRequest] = []

    var placeStagedCalls: [String] = []

    func placeStagedWrapper(
        stagingToken: String, finalURL: URL, bookmark: String?
    ) async throws -> WrapperInfo {
        count("placeStagedWrapper")
        placeStagedCalls.append(stagingToken)
        return WrapperInfo(
            summary: WrapperSummary(
                packageID: RuntimePackageID(rawValue: "com.example.a")!,
                bundleID: "io.apkrun.android.com.example.a",
                displayName: "Example",
                kind: .local,
                bundleURL: finalURL,
                status: WrapperStatus(state: .valid),
                approval: .generated,
                launcherVersion: "1",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
            fileName: "Example",
            customization: WrapperCustomizationWire(),
            signer: .adHoc,
            cdhash: "0123456789abcdef0123456789abcdef01234567",
            launcherAPI: APIVersion(major: 1, minor: 0),
            formatVersion: 1)
    }

    func discardImport(_ request: RuntimeDiscardImportRequest) async throws {
        count("discardImport")
    }

    func subscribe(to topic: EventTopic) async throws -> AsyncStream<EventEnvelope> {
        AsyncStream { $0.finish() }
    }

    var details: RuntimePackageDetails?
    var settings: PackageSettingsWire?
    var integration: IntegrationStatus?
    var settingPatches: [RuntimePackageSettingsPatch] = []
    var policies: [UpdatePolicy] = []
    var authorities: [AuthorityChoice] = []
    var configValues: [String: String] = [:]
    var configSets: [(String, String)] = []

    func packageInfo(packageID: RuntimePackageID) async throws -> RuntimePackageDetails {
        count("packageInfo")
        if let error { throw error }
        return details
            ?? RuntimePackageDetails(
                summary: package(packageID.rawValue), files: [], artifactBytes: 1024)
    }

    func packageSettings(_ packageID: RuntimePackageID) async throws -> PackageSettingsWire? {
        count("packageSettings")
        return settings
    }

    func updatePackageSettings(
        _ packageID: RuntimePackageID, patch: RuntimePackageSettingsPatch
    ) async throws -> PackageSettingsWire {
        count("updatePackageSettings")
        record { settingPatches.append(patch) }
        if let error { throw error }
        return settings ?? PackageSettingsWire(groups: [:], recommended: [:], entries: [])
    }

    func integrationStatus(packageID: RuntimePackageID) async throws -> IntegrationStatus {
        count("integrationStatus")
        return integration
            ?? IntegrationStatus(packageID: packageID, items: [], microphoneNeedsRestart: false)
    }

    func setUpdatePolicy(
        packageID: RuntimePackageID, policy: UpdatePolicy
    ) async throws -> PackageUpdateStatus {
        count("setUpdatePolicy")
        record { policies.append(policy) }
        return updates.first { $0.packageID == packageID }
            ?? PackageUpdateStatus(
                packageID: packageID, choice: policy.choice, authority: "apkrun",
                provider: nil, phase: nil, candidate: nil,
                lastCheckAt: nil, nextCheckAt: nil, consecutiveFailures: 0, waiting: [])
    }

    func setUpdateAuthority(
        packageID: RuntimePackageID, authority: AuthorityChoice
    ) async throws -> PackageUpdateStatus {
        count("setUpdateAuthority")
        record { authorities.append(authority) }
        return PackageUpdateStatus(
            packageID: packageID, choice: nil, authority: authority.rawValue,
            provider: nil, phase: nil, candidate: nil,
            lastCheckAt: nil, nextCheckAt: nil, consecutiveFailures: 0, waiting: [])
    }

    func rollbackPackage(packageID: RuntimePackageID, allowDataLoss: Bool)
        async throws -> RuntimeRollbackPackageControlReply
    {
        count("rollbackPackage")
        return RuntimeRollbackPackageControlReply(rolledBackTo: 2)
    }

    func updateSkipped(packageID: RuntimePackageID, versionCode: RuntimeVersionCode, skipped: Bool)
        async throws
    {
        count("updateSkipped")
    }

    func beginUninstallPackage(
        _ request: RuntimeUninstallPackageRequest, operationID: OperationID
    ) async throws -> OperationHandle {
        count("beginUninstallPackage")
        return OperationHandle(operationID: operationID, kind: .uninstall)
    }

    func removeWrapper(packageID: RuntimePackageID, trash: Bool) async throws -> Bool {
        count("removeWrapper")
        return true
    }

    func deniedWrappers() async throws -> [DeniedWrapper] {
        count("deniedWrappers")
        return []
    }

    func clearWrapperDenial(bundleID: String, cdhash: String) async throws {
        count("clearWrapperDenial")
    }

    func getConfig(keys: [String]?) async throws -> [String: String] {
        count("getConfig")
        if let error { throw error }
        if let keys { return configValues.filter { keys.contains($0.key) } }
        return configValues
    }

    func setConfig(key: String, value: String) async throws -> [String: String] {
        count("setConfig")
        record {
            configSets.append((key, value))
            configValues[key] = value
        }
        if let error { throw error }
        return configValues
    }
}

private func package(
    _ id: String = "com.example.a",
    state: RuntimePackageState = .installed,
    authority: RuntimeUpdateAuthority = .apkrun
) -> RuntimePackageSummary {
    RuntimePackageSummary(
        packageID: RuntimePackageID(rawValue: id)!, displayName: "Example",
        versionCode: 3, versionName: "1.2", state: state,
        managed: true, updateAuthority: authority)
}

private func wrapperSummary(_ id: String = "com.example.a") -> WrapperSummary {
    WrapperSummary(
        packageID: RuntimePackageID(rawValue: id)!,
        bundleID: "io.apkrun.android.com-example-a",
        displayName: "Example", kind: .local,
        bundleURL: URL(fileURLWithPath: "/Applications/Example.app"),
        status: WrapperStatus(state: .valid), approval: .generated, launcherVersion: "1",
        createdAt: Date(), refreshedAt: nil)
}

@MainActor
final class HomeRowStatusTests: XCTestCase {
    private func status(
        package: RuntimePackageSummary = package(),
        update: PackageUpdateStatus? = nil,
        outcome: UpdateHistoryEntry? = nil,
        wrapper: WrapperListEntryWire? = nil,
        phase: WireSessionPhase? = nil
    ) -> HomeRowStatus {
        HomeRowStatus(
            package: package, update: update, lastOutcome: outcome,
            wrapper: wrapper, sessionPhase: phase)
    }

    private func updateStatus(
        phase: WireUpdatePhase? = nil,
        candidate: WireUpdateCandidate? = nil,
        waiting: [WaitingReason] = []
    ) -> PackageUpdateStatus {
        PackageUpdateStatus(
            packageID: RuntimePackageID(rawValue: "com.example.a")!,
            choice: .automatic, authority: "apkrun",
            provider: nil, phase: phase, candidate: candidate,
            lastCheckAt: nil, nextCheckAt: nil,
            consecutiveFailures: 0, waiting: waiting)
    }

    // §5.3 row 1
    func testBrokenWinsOverEverything() {
        let s = status(
            package: package(state: .broken("damaged")),
            update: updateStatus(candidate: WireUpdateCandidate(versionName: "9.9", provider: "x")),
            wrapper: WrapperListEntryWire(summary: wrapperSummary(), state: .missing))
        XCTAssertEqual(s.text, "Needs attention: damaged")
        XCTAssertEqual(s.actions, [.repair])
    }

    // §5.3 row 2
    func testInstallingShowsProgressLine() {
        XCTAssertEqual(status(package: package(state: .installing)).text, "Installing…")
        XCTAssertEqual(status(package: package(state: .uninstalling)).text, "Removing…")
        let s = status(update: updateStatus(phase: .downloading(progress: 0.4)))
        XCTAssertEqual(s.text, "Updating…")
        XCTAssertEqual(s.progress, 0.4)
        XCTAssertEqual(status(update: updateStatus(phase: .validating)).text, "Updating…")
    }

    // §5.3 row 3
    func testFailedAndRolledBack() {
        let failed = UpdateHistoryEntry(
            v: 1, time: Date(), packageID: RuntimePackageID(rawValue: "com.example.a")!,
            from: 3, to: 4, provider: nil, trigger: "scheduled",
            outcome: "skipped.installFailed", failure: WireError(domain: "update", code: "installFailed"),
            phaseDurationsMs: [:])
        XCTAssertEqual(status(outcome: failed).text, "Update failed")
        XCTAssertEqual(status(outcome: failed).actions, [.details])
        let rolled = UpdateHistoryEntry(
            v: 1, time: Date(), packageID: RuntimePackageID(rawValue: "com.example.a")!,
            from: 3, to: 4, provider: nil, trigger: "automatic",
            outcome: "rolledBack", failure: nil, phaseDurationsMs: [:])
        XCTAssertEqual(status(outcome: rolled).text, "Rolled back to 3")
    }

    // §5.3 row 4
    func testWaitingRows() {
        let s = status(update: updateStatus(waiting: [.appInUse]))
        XCTAssertEqual(s.text, "Will update when Example quits")
        XCTAssertEqual(s.actions, [.updateNow])
    }

    // §5.3 row 5
    func testAvailableBeatsWrapperStates() {
        let s = status(
            update: updateStatus(candidate: WireUpdateCandidate(versionName: "2.0", provider: "x")),
            wrapper: WrapperListEntryWire(summary: wrapperSummary(), state: .missing))
        XCTAssertEqual(s.text, "Update available 2.0")
        XCTAssertEqual(s.actions, [.updateNow])
    }

    // §5.3 row 6 / wrapper.md §9.1
    func testWrapperStates() {
        func s(_ state: WrapperState) -> HomeRowStatus {
            status(wrapper: WrapperListEntryWire(summary: wrapperSummary(), state: state))
        }
        XCTAssertEqual(s(.missing).text, "Mac app not found")
        XCTAssertEqual(s(.missing).actions, [.createMacApp])
        XCTAssertEqual(s(.inaccessible).text, "APKRun can't check this location")
        XCTAssertEqual(s(.inaccessible).actions, [])
        XCTAssertEqual(s(.signatureInvalid).text, "This Mac app was modified")
        XCTAssertEqual(s(.signatureInvalid).actions, [.createItAgain])
        XCTAssertEqual(s(.unknownPackage).text, "Example isn't installed")
        XCTAssertEqual(s(.unknownPackage).actions, [.trashMacApp])
    }

    // §5.3 row 7
    func testRefreshReasons() {
        let s = status(
            wrapper: WrapperListEntryWire(
                summary: wrapperSummary(), state: .valid,
                refreshReasons: [.icon]))
        XCTAssertEqual(s.text, "Mac app can be updated")
        XCTAssertEqual(s.actions, [.updateMacApp])
    }

    // §5.3 row 8
    func testFallbackRows() {
        XCTAssertEqual(status().text, "Up to date")
        XCTAssertEqual(status().actions, [.openAndSettings])
        XCTAssertEqual(status(package: package(authority: .manual)).text, "Updates: Manual")
    }

    func testRunningDot() {
        XCTAssertTrue(status(phase: .running).isRunning)
        XCTAssertTrue(status(phase: .backgrounded).isRunning)
        XCTAssertFalse(status(phase: .closing).isRunning)
        XCTAssertFalse(status().isRunning)
    }
}

@MainActor
final class AppRouterTests: XCTestCase {
    func testKnownRoutes() {
        XCTAssertEqual(AppRouter.route(URL(string: "apkrun://home")!), .home)
        XCTAssertEqual(AppRouter.route(URL(string: "apkrun://updates")!), .updates)
        XCTAssertEqual(AppRouter.route(URL(string: "apkrun://setup")!), .setup)
        XCTAssertEqual(
            AppRouter.route(URL(string: "apkrun://package/com.example.a")!),
            .package(RuntimePackageID(rawValue: "com.example.a")!, section: nil))
        XCTAssertEqual(
            AppRouter.route(URL(string: "apkrun://package/com.example.a/updates")!),
            .package(RuntimePackageID(rawValue: "com.example.a")!, section: "updates"))
        XCTAssertEqual(
            AppRouter.route(URL(string: "apkrun://settings/updates")!),
            .settings(pane: "updates"))
    }

    func testUnknownRoutesLandHome() {
        XCTAssertEqual(AppRouter.route(URL(string: "apkrun://report")!), .home)
        XCTAssertEqual(AppRouter.route(URL(string: "apkrun://bogus/x")!), .home)
        XCTAssertEqual(
            AppRouter.route(URL(string: "apkrun://settings/nonsense")!),
            .settings(pane: "general"))
    }

    func testInvalidPackageIDsRejected() {
        XCTAssertNil(AppRouter.route(URL(string: "apkrun://package/not a package")!))
        XCTAssertNil(AppRouter.route(URL(string: "apkrun://package/../../etc")!))
        XCTAssertNil(AppRouter.route(URL(string: "https://example.com/")!))
    }

    func testPackageIDGrammar() {
        XCTAssertNotNil(RuntimePackageID(rawValue: "com.example.app"))
        XCTAssertNil(RuntimePackageID(rawValue: "NoDots"))
        XCTAssertNil(RuntimePackageID(rawValue: ""))
    }
}

@MainActor
final class HomeModelTests: XCTestCase {
    private func model(with service: FakeRuntimeService) -> HomeModel {
        HomeModel { service }
    }

    func testPackageListSplitsManagedAndOther() async {
        let service = FakeRuntimeService()
        service.packages = [
            package(),
            RuntimePackageSummary(
                packageID: RuntimePackageID(rawValue: "com.other.b")!,
                displayName: "Other", versionCode: 1, versionName: nil,
                state: .installed, managed: false, updateAuthority: .external),
        ]
        let m = model(with: service)
        await m.packages.reload()
        XCTAssertEqual(m.packages.managed.count, 1)
        XCTAssertEqual(m.packages.other.map(\.packageID.rawValue), ["com.other.b"])
    }

    func testReconnectClearsUnreachableFlag() async {
        let service = FakeRuntimeService()
        service.error = RuntimeWireError(domain: "runtime", code: "x", message: "down")
        let m = model(with: service)
        await m.packages.reload()
        XCTAssertTrue(m.packages.serviceUnreachable)
        service.error = nil
        service.packages = [package()]
        await m.packages.reload()
        XCTAssertFalse(m.packages.serviceUnreachable)
        XCTAssertEqual(m.packages.managed.count, 1)
    }

    func testUpdatesBadgeCountsActionableRows() async {
        let service = FakeRuntimeService()
        service.updates = [
            PackageUpdateStatus(
                packageID: RuntimePackageID(rawValue: "com.example.a")!,
                choice: .automatic, authority: "apkrun", provider: nil,
                phase: nil,
                candidate: WireUpdateCandidate(versionName: "2", provider: "p"),
                lastCheckAt: nil, nextCheckAt: nil, consecutiveFailures: 0, waiting: []),
            PackageUpdateStatus(
                packageID: RuntimePackageID(rawValue: "com.example.b")!,
                choice: .automatic, authority: "apkrun", provider: nil,
                phase: nil, candidate: nil,
                lastCheckAt: nil, nextCheckAt: nil, consecutiveFailures: 0, waiting: []),
        ]
        let m = model(with: service)
        await m.updates.reload()
        XCTAssertEqual(m.updates.badgeCount, 1)
    }

    func testRouterAppliesPackageRoute() async {
        let service = FakeRuntimeService()
        service.packages = [package()]
        let m = model(with: service)
        await m.packages.reload()
        m.apply(.package(RuntimePackageID(rawValue: "com.example.a")!, section: nil))
        XCTAssertEqual(m.selection, .apps)
        XCTAssertNil(m.missingPackageID)
        m.apply(.package(RuntimePackageID(rawValue: "com.absent.z")!, section: nil))
        XCTAssertEqual(m.missingPackageID, "com.absent.z")
        m.apply(.updates)
        XCTAssertEqual(m.selection, .updates)
    }
}

@MainActor
final class AddFlowModelTests: XCTestCase {
    private func flow(with service: FakeRuntimeService) -> AddFlowModel {
        AddFlowModel { service }
    }

    private func preview(
        relation: RuntimeImportRelation = .newPackage,
        name: String = "Hello Text"
    ) -> RuntimeImportPreview {
        RuntimeImportPreview(
            ticket: RuntimeImportTicket(rawValue: "1d83472f-3568-4c16-84a0-267fa5b3d534")!,
            packageID: RuntimePackageID(rawValue: "com.example.a")!,
            displayName: name,
            versionCode: 3,
            versionName: "1.2",
            signerDigests: [],
            files: [],
            excludedSplits: [],
            relation: relation,
            warnings: [])
    }

    // Every §6.1 relation maps to its sheet and button.
    func testRelationSheets() {
        func sheet(_ r: RuntimeImportRelation) -> AddFlowSheet {
            AddFlowSheet(relation: r, displayName: "Discord", version: "2.0")
        }
        XCTAssertEqual(sheet(.newPackage).action, "Install")
        XCTAssertTrue(sheet(.newPackage).showsOptions)
        let same = sheet(.sameAsInstalled)
        XCTAssertEqual(same.headline, "Discord 2.0 is already installed.")
        XCTAssertNil(same.action)
        XCTAssertFalse(same.showsOptions)
        XCTAssertEqual(sheet(.reinstallSameVersion).action, "Reinstall")
        let update = sheet(.update(from: 1))
        XCTAssertEqual(update.headline, "Update Discord from 1 to 2.0?")
        XCTAssertEqual(update.action, "Update")
        let downgrade = sheet(.downgrade(from: 9))
        XCTAssertNil(downgrade.action)
        XCTAssertFalse(downgrade.showsOptions)
        let other = sheet(.otherSigner)
        XCTAssertNil(other.action)
        XCTAssertFalse(other.showsOptions)
        XCTAssertEqual(sheet(.uninstalledWithData(1)).action, "Reinstall")
    }

    // Update modes: Manual-only without a source; suggestion off by default.
    func testUpdateChoiceDefaults() {
        let m = flow(with: FakeRuntimeService())
        XCTAssertEqual(m.updateChoice, .manual)
        XCTAssertNil(m.suggestedProvider)
    }

    // §6.1: Mac app name starts with the host label; location starts at the
    // configured default.
    func testMacAppDefaults() async {
        let service = FakeRuntimeService()
        service.previewToReturn = preview(name: "OddName App")
        let m = flow(with: service)
        // Feed the preview directly: begin() opens real files, so tests
        // inject through the seam below instead.
        await m.inspectForTesting(preview(name: "OddName App"))
        XCTAssertEqual(m.macAppName, "OddName App")
        XCTAssertEqual(m.location, .userApplications)
        XCTAssertTrue(m.createMacApp)
    }

    // Install sends the ticket; the wrapper goes through its own operation
    // with the chosen name and location (§6.1).
    func testInstallPassesOptions() async {
        let service = FakeRuntimeService()
        let m = flow(with: service)
        await m.inspectForTesting(preview(name: "OddName App"))
        m.createMacApp = true
        m.location = .allApplications
        m.install()
        // The install + wrapper run on a Task; give them a tick.
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.installRequests.count, 1)
        let request = service.installRequests[0]
        XCTAssertFalse(request.options.createWrapper)
        XCTAssertEqual(request.options.authority, .manual)
        XCTAssertEqual(service.wrapperRequests.count, 1)
        let wrapper = service.wrapperRequests[0]
        XCTAssertEqual(wrapper.destination, .applications)
        XCTAssertEqual(wrapper.fileName, "OddName App")
        XCTAssertEqual(wrapper.displayName, "OddName App")
    }

    // §6.1: without an update source only Manual can be sent (the daemon
    // refuses apkrun authority without a provider).
    func testAutomaticWithoutProviderFallsBackToManual() async {
        let service = FakeRuntimeService()
        let m = flow(with: service)
        await m.inspectForTesting(preview())
        m.updateChoice = .automatic
        m.install()
        try? await Task.sleep(for: .milliseconds(50))
        let request = service.installRequests[0]
        XCTAssertEqual(request.options.authority, .manual)
        XCTAssertEqual(m.updateChoice, .manual)
    }

    func testRefusedFilesFailFast() async {
        let m = flow(with: FakeRuntimeService())
        m.begin(urls: [URL(fileURLWithPath: "/tmp/photo.png")])
        XCTAssertEqual(m.stage, .failed("APKRun can add .apk, .apks, .xapk, and .apkm files."))
    }
}

// MARK: - #80 app page and settings panes

private func wireEntry(
    _ key: String, _ value: String,
    source: String = "default", appliesLive: Bool = true, stored: String? = nil
) -> PackageSettingWire {
    PackageSettingWire(
        key: key, value: value, source: source, appliesLive: appliesLive,
        stored: stored, allowed: nil)
}

@MainActor
final class PackageDetailModelTests: XCTestCase {
    private func model(
        service: FakeRuntimeService,
        settings: PackageSettingsWire? = nil
    ) -> PackageDetailModel {
        service.settings = settings
        return PackageDetailModel(
            packageID: RuntimePackageID(rawValue: "com.example.a")!,
            makeService: { service })
    }

    /// Issue #80 T0: every control writes its key and value at once.
    func testSetWritesKeyAndValue() async {
        let service = FakeRuntimeService()
        let m = model(
            service: service,
            settings: PackageSettingsWire(
                groups: [:], recommended: [:],
                entries: [wireEntry("window.resizable", "true")]))
        m.set("window.resizable", "false")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.callCounts["updatePackageSettings"], 1)
        XCTAssertEqual(service.settingPatches.first?.set["window.resizable"], "false")
    }

    /// Issue #80 T0: Reset clears the stored value (sends the clear list).
    func testResetClearsKey() async {
        let service = FakeRuntimeService()
        let m = model(service: service)
        m.reset("window.alwaysOnTop")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.settingPatches.first?.clear, ["window.alwaysOnTop"])
        XCTAssertTrue(service.settingPatches.first?.set.isEmpty ?? false)
    }

    /// Issue #80 T0: a change to a next-session key shows the note.
    func testNextSessionKeyShowsNote() async {
        let service = FakeRuntimeService()
        let m = model(
            service: service,
            settings: PackageSettingsWire(
                groups: [:], recommended: [:],
                entries: [wireEntry("window.mode", "primaryDisplayCompatibility", appliesLive: false)]))
        m.set("window.mode", "primaryDisplayCompatibility")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(m.appliesNextOpenNotice)
    }

    /// Issue #80 T0: recommended keys show the marker and Reset.
    func testRecommendedMarkerAndCustomizedReset() async {
        let service = FakeRuntimeService()
        let m = model(
            service: service,
            settings: PackageSettingsWire(
                groups: [:], recommended: [:],
                entries: [
                    wireEntry("input.hover", "false", source: "recommended"),
                    wireEntry("window.zoom", "1.25", source: "user", stored: "1.25"),
                    wireEntry("input.escapeKey", "back"),
                ]))
        await m.load()
        XCTAssertTrue(m.isRecommended("input.hover"))
        XCTAssertTrue(m.isCustomized("window.zoom"))
        XCTAssertFalse(m.isCustomized("input.escapeKey"))
        XCTAssertEqual(m.value("window.zoom"), "1.25")
    }

    /// Issue #80 T0: Updated by → external asks first; confirming sends it.
    func testExternalAuthorityAsksFirst() async {
        let service = FakeRuntimeService()
        service.updates = [
            PackageUpdateStatus(
                packageID: RuntimePackageID(rawValue: "com.example.a")!,
                choice: nil, authority: "apkrun", provider: nil, phase: nil,
                candidate: nil, lastCheckAt: nil, nextCheckAt: nil,
                consecutiveFailures: 0, waiting: [])
        ]
        let m = model(service: service)
        await m.load()
        m.pickAuthority(.external)
        XCTAssertTrue(m.confirmExternalAuthority)
        XCTAssertEqual(service.callCounts["setUpdateAuthority"] ?? 0, 0)
        m.confirmExternal()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.authorities, [.external])
    }

    /// Issue #80 T0: the mode picker writes through setUpdatePolicy.
    func testModeWritesPolicy() async {
        let service = FakeRuntimeService()
        let m = model(service: service)
        m.setMode(.notifyOnly)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.policies.first?.choice, .notifyOnly)
        XCTAssertEqual(service.callCounts["updatePackageSettings"] ?? 0, 0)
    }

    /// Issue #80 T0: the header's Open and Update Now call the wire ops.
    func testHeaderActions() async {
        let service = FakeRuntimeService()
        let m = model(service: service)
        m.open()
        m.updateNow()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.callCounts["launch"], 1)
        XCTAssertEqual(service.callCounts["updatePackage"], 1)
    }
}

@MainActor
final class SettingsModelTests: XCTestCase {
    /// Issue #80 T0: each pane control writes its key and value at once.
    func testSetWritesConfigKey() async {
        let service = FakeRuntimeService()
        let m = SettingsModel(makeService: { service })
        m.set("runtime.idleSuspendMinutes", "30")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.configSets.first?.0, "runtime.idleSuspendMinutes")
        XCTAssertEqual(service.configSets.first?.1, "30")
        XCTAssertEqual(m.value("runtime.idleSuspendMinutes"), "30")
    }

    /// Issue #80 T0: Developer mode turns on only after confirmation.
    func testDeveloperModeAsksFirst() async {
        let service = FakeRuntimeService()
        let m = SettingsModel(makeService: { service })
        m.injectValues(["developer.enabled": "false"])
        m.pickDeveloperMode(true)
        XCTAssertTrue(m.confirmDeveloperMode)
        XCTAssertTrue(service.configSets.isEmpty)
        m.confirmDeveloperModeOn()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.configSets.first?.1, "true")
    }

    /// Issue #80 T0: turning Developer mode off asks nothing.
    func testDeveloperModeOffNeedsNoConfirmation() async {
        let service = FakeRuntimeService()
        let m = SettingsModel(makeService: { service })
        m.injectValues(["developer.enabled": "true"])
        m.pickDeveloperMode(false)
        XCTAssertFalse(m.confirmDeveloperMode)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(service.configSets.first?.1, "false")
    }
}
