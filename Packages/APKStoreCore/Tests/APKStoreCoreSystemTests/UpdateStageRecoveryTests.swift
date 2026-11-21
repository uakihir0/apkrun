import Foundation
import Testing

@testable import APKStoreCore

// T1 of #38: process-crash recovery of stage/discardStaged at every journaled
// step (package-store.md §5.5). An in-process injected crash stands in for the
// process exit the APKRUN_STORE_FAULT hook performs.

private struct InjectedStoreCrash: Error {}

private actor StageRecoveryChannel: StoreAgentChannel {
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

private struct StageRecoveryRuntime: StoreRuntimeAccess {
    let channel: StageRecoveryChannel

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
    runtime: StageRecoveryRuntime,
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

/// Installs V1 and imports V2, returning the store pieces a stage test needs.
private func installV1AndImportV2(
    at packages: URL,
    runtime: StageRecoveryRuntime,
    crashAt: (kind: String, step: String)? = nil
) async throws -> (PackageStore, PackageRecord, UUID, StagedUpdateInfo) {
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
    return (store, record, v2.ticket, candidate)
}

private func makePackagesRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateStageRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    let packages = root.appendingPathComponent("Packages", isDirectory: true)
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    return root
}

// stage crashes at `begin` (before any journaled file step): recovery aborts the
// transaction and the package has no staged set.
@Test func stageCrashAtBeginAborts() async throws {
    for step in ["begin"] {
        let root = try makePackagesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = root.appendingPathComponent("Packages")
        let runtime = StageRecoveryRuntime(channel: StageRecoveryChannel())
        let (store, record, ticket, candidate) = try await installV1AndImportV2(
            at: packages, runtime: runtime, crashAt: ("stage", step))
        do {
            try await store.stage(ticket: ticket, candidate: candidate)
            Issue.record("stage must throw at \(step)")
        } catch is InjectedStoreCrash {}

        let recovered = makeStore(at: packages, runtime: runtime)
        try await recovered.open()
        try await recovered.recoverPendingTransactions()
        let reloaded = try #require(
            await recovered.listManagedPackages().first { $0.packageId == record.packageId })
        #expect(reloaded.artifacts.staged == nil)
    }
}

// stage crashes after a journaled step (filesStaged, metadataWritten): recovery
// rolls forward and the record reports the staged set.
@Test func stageCrashAfterFileStepRollsForward() async throws {
    for step in ["filesStaged", "metadataWritten"] {
        let root = try makePackagesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = root.appendingPathComponent("Packages")
        let runtime = StageRecoveryRuntime(channel: StageRecoveryChannel())
        let (store, record, ticket, candidate) = try await installV1AndImportV2(
            at: packages, runtime: runtime, crashAt: ("stage", step))
        do {
            try await store.stage(ticket: ticket, candidate: candidate)
            Issue.record("stage must throw at \(step)")
        } catch is InjectedStoreCrash {}

        let recovered = makeStore(at: packages, runtime: runtime)
        try await recovered.open()
        try await recovered.recoverPendingTransactions()
        let reloaded = try #require(
            await recovered.listManagedPackages().first { $0.packageId == record.packageId })
        #expect(reloaded.artifacts.staged?.versionCode == 2)
        #expect(reloaded.artifacts.staged?.origin.type == .local)
    }
}

// discardStaged crashes at `begin`: recovery aborts and the staged set survives.
@Test func discardStagedCrashAtBeginKeepsStaged() async throws {
    let root = try makePackagesRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let runtime = StageRecoveryRuntime(channel: StageRecoveryChannel())
    let (store, record, ticket, candidate) = try await installV1AndImportV2(
        at: packages, runtime: runtime)
    try await store.stage(ticket: ticket, candidate: candidate)

    let crashing = makeStore(at: packages, runtime: runtime, crashAt: ("discardStaged", "begin"))
    try await crashing.open()
    do {
        try await crashing.discardStaged(packageID: record.packageId)
        Issue.record("discardStaged must throw at begin")
    } catch is InjectedStoreCrash {}

    let recovered = makeStore(at: packages, runtime: runtime)
    try await recovered.open()
    try await recovered.recoverPendingTransactions()
    let reloaded = try #require(
        await recovered.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(reloaded.artifacts.staged?.versionCode == 2)
}

// discardStaged crashes after a journaled file step: recovery finishes the
// removal and the staged set is gone.
@Test func discardStagedCrashAfterFileStepClearsStaged() async throws {
    for step in ["filesRemoved", "metadataWritten"] {
        let root = try makePackagesRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packages = root.appendingPathComponent("Packages")
        let runtime = StageRecoveryRuntime(channel: StageRecoveryChannel())
        let (store, record, ticket, candidate) = try await installV1AndImportV2(
            at: packages, runtime: runtime)
        try await store.stage(ticket: ticket, candidate: candidate)

        let crashing = makeStore(at: packages, runtime: runtime, crashAt: ("discardStaged", step))
        try await crashing.open()
        do {
            try await crashing.discardStaged(packageID: record.packageId)
            Issue.record("discardStaged must throw at \(step)")
        } catch is InjectedStoreCrash {}

        let recovered = makeStore(at: packages, runtime: runtime)
        try await recovered.open()
        try await recovered.recoverPendingTransactions()
        let reloaded = try #require(
            await recovered.listManagedPackages().first { $0.packageId == record.packageId })
        #expect(reloaded.artifacts.staged == nil)
    }
}
