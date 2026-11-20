import Foundation
import Testing

@testable import APKStoreCore

// T1 of #44: the `rollback` transaction — journal steps of package-store.md
// §5.2, the `failed/<versionCode>/` slot, `previous/` becoming `current/`,
// §5.5 crash recovery, and the §7.3 mechanism order
// (`.rollback` → `.downgradeReinstall` → data-loss fallback).

private struct InjectedRollbackCrash: Error {}

private actor RollbackChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities
    private var installed: [PackageID: StorePackageInfo] = [:]
    var installs: [StoreInstallRequest] = []
    var uninstalls: [PackageID] = []
    var rollbackCalls: [(from: VersionCode, to: VersionCode)] = []
    var rollbackAnswer: StoreRollbackResult = .rolledBack

    init(capabilities: StoreCapabilities) {
        self.capabilities = capabilities
    }

    func install(_ request: StoreInstallRequest, files _: [URL]) async throws -> StorePackageInfo {
        installs.append(request)
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "HelloUpdate",
            versionCode: request.versionCode,
            enabled: true,
            targetSDK: 37,
            minSDK: 29)
        installed[request.packageID] = info
        return info
    }

    func uninstall(_ package: PackageID, keepData _: Bool) async throws {
        uninstalls.append(package)
        installed[package] = nil
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        installed[package]
    }

    func listPackages(_: StorePackageFilter) async throws -> [StorePackageSummary] { [] }

    func rollback(
        _ package: PackageID, from: VersionCode, to: VersionCode
    ) async throws -> StoreRollbackResult {
        rollbackCalls.append((from: from, to: to))
        guard case .rolledBack = rollbackAnswer else { return rollbackAnswer }
        // A real RollbackManager rolls Android back to `to`.
        let info = StorePackageInfo(
            packageID: package, displayName: "HelloUpdate", versionCode: to,
            enabled: true, targetSDK: 37, minSDK: 29)
        installed[package] = info
        return .rolledBack
    }
}

private struct RollbackRuntime: StoreRuntimeAccess {
    let channel: RollbackChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private func makeRollbackStore(
    at packages: URL,
    runtime: RollbackRuntime,
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
                throw InjectedRollbackCrash()
            }
        },
        importVerifier: PackageStore.legacyImportVerifier)
}

/// Installs V1 and updates to V2, leaving `previous/` = V1, `current/` = V2.
private func installV1UpdateV2(
    at packages: URL,
    runtime: RollbackRuntime
) async throws -> PackageRecord {
    let store = makeRollbackStore(at: packages, runtime: runtime)
    try await store.open()
    let root = packages.deletingLastPathComponent()
    let v1File = root.appendingPathComponent("v1.apk")
    let v2File = root.appendingPathComponent("v2.apk")
    try Data("v1 apk bytes".utf8).write(to: v1File)
    try Data("v2 apk bytes".utf8).write(to: v2File)
    let v1 = try await store.importPackage(files: [v1File])
    let record = try await store.installImported(ticket: v1.ticket)
    let v2 = try await store.importPackage(files: [v2File])
    try await store.stage(
        ticket: v2.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2, versionName: "2.0",
            setDigest: try ArtifactSet.computeSetDigest(for: v2.artifactSet.files),
            size: 13, fileCount: 1,
            origin: ArtifactOrigin(type: .local)))
    return try await store.installStaged(
        for: record.packageId, enableRollback: true, hasOpenSession: { false })
}

private func makeRollbackRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RollbackTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Packages"), withIntermediateDirectories: true)
    return root
}

// §7.3 mechanism order: with `.rollback` advertised, the channel's
// RollbackManager call restores V1 — `current/` holds V1 and V2's set lives
// in `failed/2/`.
@Test func rollbackUsesRollbackManagerWhenAdvertised() async throws {
    let root = try makeRollbackRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let channel = RollbackChannel(capabilities: [.install, .metadata, .rollback])
    let store = makeRollbackStore(
        at: packages, runtime: RollbackRuntime(channel: channel))
    try await store.open()
    let rootURL = packages.deletingLastPathComponent()
    try Data("v1 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v1.apk"))
    try Data("v2 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v2.apk"))
    let v1 = try await store.importPackage(files: [rootURL.appendingPathComponent("v1.apk")])
    let record = try await store.installImported(ticket: v1.ticket)
    let v2 = try await store.importPackage(files: [rootURL.appendingPathComponent("v2.apk")])
    try await store.stage(
        ticket: v2.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2, versionName: "2.0",
            setDigest: try ArtifactSet.computeSetDigest(for: v2.artifactSet.files),
            size: 13, fileCount: 1,
            origin: ArtifactOrigin(type: .local)))
    _ = try await store.installStaged(
        for: record.packageId, enableRollback: true, hasOpenSession: { false })

    let restored = try await store.rollback(
        packageID: record.packageId, allowDataLoss: false, reason: "healthCheck.H3")

    let calls = await channel.rollbackCalls
    #expect(calls.count == 1)
    #expect(calls.first?.from == 2)
    #expect(calls.first?.to == 1)
    #expect(restored.versionCode == 1)
    #expect(restored.artifacts.previous == nil)
    #expect(restored.lastOperation?.kind == .rollback)
    #expect(restored.lastOperation?.fromVersionCode == 2)
    #expect(restored.lastOperation?.toVersionCode == 1)
    // V2's set moved to failed/2/; current/ is V1.
    let directory = packages.appendingPathComponent(record.packageId.rawValue)
    #expect(
        FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("failed/2/artifact.json").path))
    #expect(
        !FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("previous/artifact.json").path))
}

// §7.3: without `.rollback` but with `.downgradeReinstall`, rollback is an
// `install-multiple -r -d` of `previous/` — one install with
// `allowDowngrade`.
@Test func rollbackFallsBackToDowngradeReinstall() async throws {
    let root = try makeRollbackRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let channel = RollbackChannel(capabilities: [.install, .metadata, .downgradeReinstall])
    let store = makeRollbackStore(
        at: packages, runtime: RollbackRuntime(channel: channel))
    try await store.open()
    let rootURL = packages.deletingLastPathComponent()
    try Data("v1 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v1.apk"))
    try Data("v2 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v2.apk"))
    let v1 = try await store.importPackage(files: [rootURL.appendingPathComponent("v1.apk")])
    let record = try await store.installImported(ticket: v1.ticket)
    let v2 = try await store.importPackage(files: [rootURL.appendingPathComponent("v2.apk")])
    try await store.stage(
        ticket: v2.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2, versionName: "2.0",
            setDigest: try ArtifactSet.computeSetDigest(for: v2.artifactSet.files),
            size: 13, fileCount: 1,
            origin: ArtifactOrigin(type: .local)))
    _ = try await store.installStaged(
        for: record.packageId, enableRollback: true, hasOpenSession: { false })
    let installsBefore = await channel.installs.count

    let restored = try await store.rollback(
        packageID: record.packageId, allowDataLoss: false, reason: "userRequested")

    #expect(await channel.rollbackCalls.isEmpty)
    let rollbackInstall = await channel.installs.dropFirst(installsBefore).first
    #expect(rollbackInstall?.allowDowngrade == true)
    #expect(rollbackInstall?.versionCode == 1)
    #expect(restored.versionCode == 1)
}

// §7.3: no mechanism and no allowDataLoss → rollbackUnavailable; a rollback
// without `previous/` → rollbackUnavailable(.noPreviousSet).
@Test func rollbackWithoutMechanismOrPreviousIsUnavailable() async throws {
    let root = try makeRollbackRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let channel = RollbackChannel(capabilities: [.install, .metadata])
    let store = makeRollbackStore(
        at: packages, runtime: RollbackRuntime(channel: channel))
    try await store.open()
    let rootURL = packages.deletingLastPathComponent()
    try Data("v1 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v1.apk"))
    try Data("v2 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v2.apk"))
    let v1 = try await store.importPackage(files: [rootURL.appendingPathComponent("v1.apk")])
    let record = try await store.installImported(ticket: v1.ticket)

    // No previous/ at all.
    do {
        _ = try await store.rollback(
            packageID: record.packageId, allowDataLoss: false, reason: "userRequested")
        Issue.record("expected rollbackUnavailable")
    } catch PackageStoreFailure.rollbackUnavailable(let reason) {
        #expect(reason == .noPreviousSet)
    }

    // previous/ exists but no mechanism and data loss not allowed.
    let v2 = try await store.importPackage(files: [rootURL.appendingPathComponent("v2.apk")])
    try await store.stage(
        ticket: v2.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2, versionName: "2.0",
            setDigest: try ArtifactSet.computeSetDigest(for: v2.artifactSet.files),
            size: 13, fileCount: 1,
            origin: ArtifactOrigin(type: .local)))
    _ = try await store.installStaged(
        for: record.packageId, enableRollback: true, hasOpenSession: { false })
    do {
        _ = try await store.rollback(
            packageID: record.packageId, allowDataLoss: false, reason: "userRequested")
        Issue.record("expected rollbackUnavailable")
    } catch PackageStoreFailure.rollbackUnavailable(let reason) {
        #expect(reason == .noMechanism)
    }
}

// §7.3 data-loss fallback: only `allowDataLoss` permits uninstall + first
// install of `previous/`.
@Test func rollbackWithDataLossUninstallsAndReinstalls() async throws {
    let root = try makeRollbackRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let channel = RollbackChannel(capabilities: [.install, .metadata])
    let store = makeRollbackStore(
        at: packages, runtime: RollbackRuntime(channel: channel))
    try await store.open()
    let rootURL = packages.deletingLastPathComponent()
    try Data("v1 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v1.apk"))
    try Data("v2 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v2.apk"))
    let v1 = try await store.importPackage(files: [rootURL.appendingPathComponent("v1.apk")])
    let record = try await store.installImported(ticket: v1.ticket)
    let v2 = try await store.importPackage(files: [rootURL.appendingPathComponent("v2.apk")])
    try await store.stage(
        ticket: v2.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2, versionName: "2.0",
            setDigest: try ArtifactSet.computeSetDigest(for: v2.artifactSet.files),
            size: 13, fileCount: 1,
            origin: ArtifactOrigin(type: .local)))
    _ = try await store.installStaged(
        for: record.packageId, enableRollback: true, hasOpenSession: { false })
    let installsBefore = await channel.installs.count

    let restored = try await store.rollback(
        packageID: record.packageId, allowDataLoss: true, reason: "userRequested")

    #expect(await channel.uninstalls == [record.packageId])
    let reinstall = await channel.installs.dropFirst(installsBefore).first
    #expect(reinstall?.versionCode == 1)
    #expect(restored.versionCode == 1)
}

// §5.5: a crash after `guestRolledBack` (at `filesRestored`) is reconciled
// post-boot — the guest already reports `to`, so recovery finishes the
// restore: current/ = V1, operation = rollback.
@Test func rollbackRecoveryFinishesWhenRolledBack() async throws {
    let root = try makeRollbackRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages")
    let channel = RollbackChannel(capabilities: [.install, .metadata, .rollback])
    var runtime = RollbackRuntime(channel: channel)
    let store = makeRollbackStore(
        at: packages, runtime: runtime,
        crashAt: (kind: "rollback", step: "filesRestored"))
    try await store.open()
    let rootURL = packages.deletingLastPathComponent()
    try Data("v1 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v1.apk"))
    try Data("v2 apk bytes".utf8).write(to: rootURL.appendingPathComponent("v2.apk"))
    let v1 = try await store.importPackage(files: [rootURL.appendingPathComponent("v1.apk")])
    let record = try await store.installImported(ticket: v1.ticket)
    let v2 = try await store.importPackage(files: [rootURL.appendingPathComponent("v2.apk")])
    try await store.stage(
        ticket: v2.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2, versionName: "2.0",
            setDigest: try ArtifactSet.computeSetDigest(for: v2.artifactSet.files),
            size: 13, fileCount: 1,
            origin: ArtifactOrigin(type: .local)))
    _ = try await store.installStaged(
        for: record.packageId, enableRollback: true, hasOpenSession: { false })

    do {
        _ = try await store.rollback(
            packageID: record.packageId, allowDataLoss: false, reason: "healthCheck.H3")
        Issue.record("expected the injected crash")
    } catch is InjectedRollbackCrash {
    }

    // Post-boot recovery: `to` (1) installed → finish the restore.
    runtime = RollbackRuntime(channel: channel)
    let recovered = makeRollbackStore(at: packages, runtime: runtime)
    try await recovered.open()
    try await recovered.recoverPendingTransactions()
    let restored = try #require(
        await recovered.listManagedPackages().first(where: {
            $0.packageId == record.packageId
        }))
    #expect(restored.versionCode == 1)
    #expect(restored.lastOperation?.kind == .rollback)
}
