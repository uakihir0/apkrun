import APKStoreCore
import Foundation
import Testing

@testable import UpdateCore

// T1 of #38: the coordinator end to end over the committed local fixture repo
// (update-system.md §4.2, §5, §10; "up to date" with only 1, 0 never a
// candidate, notifyOnly posts once, state survives a restart).

private actor CoordinatorChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities = [.install, .metadata]
    private var packages: [PackageID: StorePackageInfo] = [:]

    func install(_ request: StoreInstallRequest, files _: [URL]) async throws -> StorePackageInfo {
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "HelloUpdate",
            versionCode: request.versionCode,
            enabled: true,
            targetSDK: 37,
            minSDK: 29)
        packages[request.packageID] = info
        return info
    }

    func uninstall(_ package: PackageID, keepData _: Bool) async throws {
        packages[package] = nil
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        packages[package]
    }

    func listPackages(_: StorePackageFilter) async throws -> [StorePackageSummary] {
        []
    }
}

private struct CoordinatorRuntime: StoreRuntimeAccess {
    let channel: CoordinatorChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private struct FailingHTTP: UpdateHTTPClient {
    func get(_: URL, headers _: [String: String]) async throws(UpdateFailure) -> HTTPResponse {
        throw UpdateFailure.providerUnreachable(reason: "no network in tests")
    }
}

private struct MemoryCache: ProviderCache {
    let root: URL
    func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct NoCredentials: ProviderCredentials {
    func token(for _: String) -> String? { nil }
    func setToken(_: String?, for _: String) throws {}
}

private actor RecordingNotifier: HostNotificationSink {
    private(set) var sent: [UpdateNotification] = []
    func notifyUpdateAvailable(_ notification: UpdateNotification) async {
        sent.append(notification)
    }
}

private let helloUpdateID = PackageID(rawValue: "io.apkrun.fixture.helloupdate")!

private func fixtureRepo() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // UpdateCoreSystemTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // UpdateCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Tests/Fixtures/update-repos/local")
}

private func makeContext(at root: URL) -> ProviderContext {
    ProviderContext(
        http: FailingHTTP(),
        cache: MemoryCache(root: root.appendingPathComponent("cache")),
        credentials: NoCredentials(),
        userInitiated: true)
}

private func makeStore(at root: URL, versionCode: VersionCode) -> PackageStore {
    PackageStore(
        packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: CoordinatorRuntime(channel: CoordinatorChannel()),
        inspector: { _ in
            APKFacts(
                packageID: helloUpdateID,
                versionCode: versionCode,
                versionName: "\(versionCode).0",
                splitName: nil,
                displayName: "HelloUpdate",
                minSDK: 29,
                targetSDK: 37,
                nativeABIs: ["arm64-v8a"])
        },
        importVerifier: PackageStore.legacyImportVerifier)
}

private func makeTemporaryRoot() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func localProviderRef(repo: URL) throws -> UpdateProviderRef {
    let bookmark = try repo.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    return UpdateProviderRef(
        type: .local,
        configuration: .local(path: repo.path, bookmark: bookmark.base64EncodedString()))
}

/// Installs V1 and attaches the local provider rooted at `repo`.
private func installV1(store: PackageStore, repo: URL) async throws -> PackageRecord {
    let apk = repo.appendingPathComponent("io.apkrun.fixture.helloupdate/1/app.apk")
    let preview = try await store.importPackage(files: [apk])
    let record = try await store.installImported(ticket: preview.ticket)
    try await store.setUpdatePolicy(
        for: record.packageId, authority: .apkrun, provider: localProviderRef(repo: repo))
    return record
}

@Test func coordinatorReportsV2AvailableFromLocalRepo() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())

    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    let coordinator = UpdateCoordinator(
        store: store, stateStore: stateStore, developerModeEnabled: { true })
    let outcome = await coordinator.check(
        record.packageId, trigger: .userInitiated, context: makeContext(at: root))

    guard case .available(let candidate) = outcome else {
        Issue.record("expected .available, got \(outcome)")
        return
    }
    #expect(candidate.declaredVersionCode == 2)
    // The local provider has no manifest; the version name stays undeclared.
    #expect(candidate.declaredVersionName == nil)
    #expect(candidate.artifacts.count == 1)
    #expect(await coordinator.phase(for: record.packageId) != nil)

    // The available phase survives a coordinator restart (state.json §10.1).
    let state = try #require(await stateStore.state(for: record.packageId))
    #expect(state.phase == "available")
    #expect(state.candidate?.versionCode == 2)
    let history = try await stateStore.history(packageID: record.packageId)
    #expect(history.last?.outcome == "available")
}

@Test func coordinatorReportsUpToDateWithOnlyV1() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // A repo that holds version 1 only (and a bogus "0" directory that must
    // never become a candidate).
    let repo = root.appendingPathComponent("repo/io.apkrun.fixture.helloupdate")
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("1"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("0"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        at: fixtureRepo().appendingPathComponent("io.apkrun.fixture.helloupdate/1/app.apk"),
        to: repo.appendingPathComponent("1/app.apk"))
    try Data("not an apk".utf8).write(to: repo.appendingPathComponent("0/app.apk"))

    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: root.appendingPathComponent("repo"))

    let coordinator = UpdateCoordinator(
        store: store,
        stateStore: UpdateStateStore(directory: root.appendingPathComponent("Updates")),
        developerModeEnabled: { true })
    let outcome = await coordinator.check(
        record.packageId, trigger: .userInitiated, context: makeContext(at: root))
    #expect(outcome == .upToDate)
}

@Test func notifyOnlyPostsOneNotificationPerCandidate() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = makeStore(at: root, versionCode: 1)
    try await store.open()
    let record = try await installV1(store: store, repo: fixtureRepo())
    try await store.setUpdateMode(for: record.packageId, mode: "notifyOnly")

    let notifier = RecordingNotifier()
    let stateStore = UpdateStateStore(directory: root.appendingPathComponent("Updates"))
    let coordinator = UpdateCoordinator(
        store: store, stateStore: stateStore,
        notifier: notifier, developerModeEnabled: { true })

    let first = await coordinator.check(
        record.packageId, trigger: .userInitiated, context: makeContext(at: root))
    guard case .available = first else {
        Issue.record("expected .available, got \(first)")
        return
    }
    #expect(await notifier.sent.count == 1)
    #expect(await notifier.sent.first?.versionCode == 2)

    // A second check on the same candidate does not notify again.
    _ = await coordinator.check(
        record.packageId, trigger: .scheduled, context: makeContext(at: root))
    #expect(await notifier.sent.count == 1)
}
