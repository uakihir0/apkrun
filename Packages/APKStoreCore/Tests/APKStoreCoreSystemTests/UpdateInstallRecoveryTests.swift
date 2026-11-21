import Foundation
import Testing

@testable import APKStoreCore

// T1 of #39: the `update` transaction — installStaged promotes `staged/` to
// `current/` and retains the old set in `previous/` (package-store.md §5.2).
// Injected crashes stand in for the process exit APKRUN_STORE_FAULT performs,
// exercising the §5.5 recovery table at every journaled step.

private struct InjectedStoreCrash: Error {}

private actor UpdateInstallChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities = [.install, .metadata, .rollback]
    private var packages: [PackageID: StorePackageInfo] = [:]
    var requests: [StoreInstallRequest] = []

    func install(_ request: StoreInstallRequest, files _: [URL]) async throws -> StorePackageInfo {
        requests.append(request)
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

private struct UpdateInstallRuntime: StoreRuntimeAccess {
    let channel: UpdateInstallChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private func makeStore(
    at packages: URL,
    runtime: UpdateInstallRuntime,
    crashAt: (kind: String, step: String)? = nil
) -> PackageStore {
    PackageStore(
        packagesDirectory: packages,
        runtimeAccess: runtime,
        inspector: { apk in
            let contents = try Data(contentsOf: apk)
            let version: VersionCode = contents == Data("v2 apk bytes".utf8) ? 2 : 1
            return APKFacts(
                packageID: PackageID(rawValue: "io.apkrun.fixture.helloupdate")!,
                versionCode: version,
                versionName: "\(version).0",
                splitName: nil,
                displayName: "HelloUpdate",
                minSDK: 29,
                targetSDK: 37,
                nativeABIs: ["arm64-v8a"])
        },
        faultInjector: { kind, step in
            if let crashAt, kind == crashAt.kind, step == crashAt.step {
                throw InjectedStoreCrash()
            }
        },
        importVerifier: PackageStore.legacyImportVerifier)
}

/// Installs V1 and stages V2, returning the store pieces an update test needs.
private func installV1AndStageV2(
    at packages: URL,
    runtime: UpdateInstallRuntime,
    crashAt: (kind: String, step: String)? = nil
) async throws -> (PackageStore, PackageRecord) {
    let store = makeStore(at: packages, runtime: runtime, crashAt: crashAt)
    try await store.open()
    let v1File = packages.deletingLastPathComponent().appendingPathComponent("v1.apk")
    let v2File = packages.deletingLastPathComponent().appendingPathComponent("v2.apk")
    try Data("v1 apk bytes".utf8).write(to: v1File)
    try Data("v2 apk bytes".utf8).write(to: v2File)

    let v1 = try await store.importPackage(files: [v1File])
    let record = try await store.installImported(ticket: v1.ticket)
    let v2 = try await store.importPackage(files: [v2File])
    let candidate = StagedUpdateInfo(
        versionCode: 2,
        versionName: "2.0",
        setDigest: try ArtifactSet.computeSetDigest(for: v2.artifactSet.files),
        size: 13,
        fileCount: 1,
        origin: ArtifactOrigin(type: .local))
    try await store.stage(ticket: v2.ticket, candidate: candidate)
    return (store, record)
}

private func makePackagesRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateInstallRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    let packages = root.appendingPathComponent("Packages", isDirectory: true)
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    return root
}

private func slotDigests(in packages: URL, record: PackageRecord) -> (
    current: String?, previous: String?, staged: String?
) {
    let directory =
        packages
        .appendingPathComponent(record.packageId.rawValue, isDirectory: true)
    func digest(_ slot: String) -> String? {
        let url = directory.appendingPathComponent(slot, isDirectory: true)
            .appendingPathComponent("artifact.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ArtifactSet.self, from: data).setDigest.rawValue
    }
    return (digest("current"), digest("previous"), digest("staged"))
}

// installStaged commits the staged set: `staged/` becomes `current/`, the old
// `current/` becomes `previous/`, the record reports the new version, and the
// update goes through one history line.
@Test func installStagedPromotesUpdate() async throws {
    let root = try makePackagesRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let runtime = UpdateInstallRuntime(channel: UpdateInstallChannel())
    let (store, record) = try await installV1AndStageV2(at: packages, runtime: runtime)
    let stagedDigest = try #require(
        await store.listManagedPackages().first?.artifacts.staged?.setDigest)

    let updated = try await store.installStaged(
        for: record.packageId, enableRollback: true, hasOpenSession: { false })

    #expect(updated.versionCode == 2)
    #expect(updated.artifacts.current?.setDigest == stagedDigest)
    #expect(updated.artifacts.previous?.versionCode == 1)
    #expect(updated.artifacts.staged == nil)
    #expect(updated.lastOperation?.kind == .update)
    #expect(updated.lastOperation?.fromVersionCode == 1)
    #expect(updated.lastOperation?.result == .succeeded)

    let digests = slotDigests(in: packages, record: updated)
    #expect(digests.current == stagedDigest.rawValue)
    #expect(digests.previous != nil && digests.previous != digests.current)
    #expect(digests.staged == nil)

    let request = try #require(await runtime.channel.requests.last)
    #expect(request.mode == .update)
    #expect(request.enableRollback)
}

// An open session blocks the update before the journal begins: the store fails
// with packageInUse and the staged set stays untouched.
@Test func installStagedWithOpenSessionFailsPackageInUse() async throws {
    let root = try makePackagesRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let runtime = UpdateInstallRuntime(channel: UpdateInstallChannel())
    let (store, record) = try await installV1AndStageV2(at: packages, runtime: runtime)

    do {
        _ = try await store.installStaged(
            for: record.packageId, enableRollback: false, hasOpenSession: { true })
        Issue.record("installStaged must fail with packageInUse")
    } catch PackageStoreFailure.packageInUse(let packageID) {
        #expect(packageID == record.packageId)
    }

    let reloaded = try #require(
        await store.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(reloaded.versionCode == 1)
    #expect(reloaded.artifacts.staged?.versionCode == 2)
    #expect(await runtime.channel.requests.last?.mode != .update)
}

// A crash at `begin`: recovery aborts and the staged set stays for a retry.
@Test func updateCrashAtBeginKeepsStaged() async throws {
    let root = try makePackagesRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let runtime = UpdateInstallRuntime(channel: UpdateInstallChannel())
    let (store, record) = try await installV1AndStageV2(
        at: packages, runtime: runtime, crashAt: ("update", "begin"))
    do {
        _ = try await store.installStaged(
            for: record.packageId, enableRollback: false, hasOpenSession: { false })
        Issue.record("installStaged must throw at begin")
    } catch is InjectedStoreCrash {}

    let recovered = makeStore(at: packages, runtime: runtime)
    try await recovered.open()
    try await recovered.recoverPendingTransactions()
    let reloaded = try #require(
        await recovered.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(reloaded.versionCode == 1)
    #expect(reloaded.artifacts.staged?.versionCode == 2)
}

// A crash at `guestCommitRequested`: the post-boot inventory shows the update
// never committed, so recovery aborts and keeps `staged/`.
@Test func updateCrashAtGuestCommitRequestedKeepsStaged() async throws {
    let root = try makePackagesRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let runtime = UpdateInstallRuntime(channel: UpdateInstallChannel())
    let (store, record) = try await installV1AndStageV2(
        at: packages, runtime: runtime, crashAt: ("update", "guestCommitRequested"))
    do {
        _ = try await store.installStaged(
            for: record.packageId, enableRollback: false, hasOpenSession: { false })
        Issue.record("installStaged must throw at guestCommitRequested")
    } catch is InjectedStoreCrash {}

    let recovered = makeStore(at: packages, runtime: runtime)
    try await recovered.open()
    try await recovered.recoverPendingTransactions()
    let reloaded = try #require(
        await recovered.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(reloaded.versionCode == 1)
    #expect(reloaded.artifacts.staged?.versionCode == 2)
}

// A crash at `guestInstalled` or `filesPromoted`: Android committed the update,
// so recovery rolls forward — renames finish by setDigest and the record
// reports the new version.
@Test func updateCrashAfterGuestInstallRollsForward() async throws {
    for step in ["guestInstalled", "filesPromoted"] {
        let root = try makePackagesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = root.appendingPathComponent("Packages")
        let runtime = UpdateInstallRuntime(channel: UpdateInstallChannel())
        let (store, record) = try await installV1AndStageV2(
            at: packages, runtime: runtime, crashAt: ("update", step))
        do {
            _ = try await store.installStaged(
                for: record.packageId, enableRollback: false, hasOpenSession: { false })
            Issue.record("installStaged must throw at \(step)")
        } catch is InjectedStoreCrash {}

        let recovered = makeStore(at: packages, runtime: runtime)
        try await recovered.open()
        try await recovered.recoverPendingTransactions()
        let reloaded = try #require(
            await recovered.listManagedPackages().first { $0.packageId == record.packageId })
        #expect(reloaded.versionCode == 2)
        #expect(reloaded.artifacts.current?.versionCode == 2)
        #expect(reloaded.artifacts.previous?.versionCode == 1)
        #expect(reloaded.artifacts.staged == nil)

        let digests = slotDigests(in: packages, record: reloaded)
        #expect(digests.current == reloaded.artifacts.current?.setDigest.rawValue)
        #expect(digests.staged == nil)
    }
}

// A crash at `metadataWritten`: the record already reports the new set, so
// recovery only commits the journal.
@Test func updateCrashAtMetadataWrittenCommits() async throws {
    let root = try makePackagesRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let runtime = UpdateInstallRuntime(channel: UpdateInstallChannel())
    let (store, record) = try await installV1AndStageV2(
        at: packages, runtime: runtime, crashAt: ("update", "metadataWritten"))
    do {
        _ = try await store.installStaged(
            for: record.packageId, enableRollback: false, hasOpenSession: { false })
        Issue.record("installStaged must throw at metadataWritten")
    } catch is InjectedStoreCrash {}

    let recovered = makeStore(at: packages, runtime: runtime)
    try await recovered.open()
    try await recovered.recoverPendingTransactions()
    let reloaded = try #require(
        await recovered.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(reloaded.versionCode == 2)
    #expect(reloaded.artifacts.current?.versionCode == 2)
    #expect(reloaded.artifacts.previous?.versionCode == 1)
    #expect(reloaded.artifacts.staged == nil)
}

// A staged set for a different version than Android's must refuse before the
// guest call when it does not increase the installed versionCode.
@Test func installStagedRefusesDowngrade() async throws {
    let root = try makePackagesRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let runtime = UpdateInstallRuntime(channel: UpdateInstallChannel())
    let (_, record) = try await installV1AndStageV2(at: packages, runtime: runtime)

    // Forge the staged set to an older version by rewriting artifact.json.
    let stagedArtifact =
        packages
        .appendingPathComponent(record.packageId.rawValue, isDirectory: true)
        .appendingPathComponent("staged/artifact.json")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var fake = try decoder.decode(ArtifactSet.self, from: Data(contentsOf: stagedArtifact))
    fake.versionCode = 1
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(fake).write(to: stagedArtifact)

    // Records cache the staged digest, so reload the store.
    let reloaded = makeStore(at: packages, runtime: runtime)
    try await reloaded.open()
    do {
        _ = try await reloaded.installStaged(
            for: record.packageId, enableRollback: false, hasOpenSession: { false })
        Issue.record("installStaged must refuse a downgrade")
    } catch PackageStoreFailure.downgradeRefused(let installed, let candidate) {
        #expect(installed == 1)
        #expect(candidate == 1)
    }
}
