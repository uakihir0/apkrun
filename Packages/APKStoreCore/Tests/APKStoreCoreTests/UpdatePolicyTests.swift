import Darwin
import Foundation
import Testing

@testable import APKStoreCore

// T0 of #38: the update authority/provider record fields, setUpdatePolicy and
// setUpdateMode, and the stage/discardStaged artifact slot (package-store.md
// §2.3, §5.5, §7.1).

private actor UpdatePolicyChannel: StoreAgentChannel {
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

private struct UpdatePolicyRuntime: StoreRuntimeAccess {
    let channel: UpdatePolicyChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private let helloUpdateID = PackageID(rawValue: "io.apkrun.fixture.helloupdate")!

private func helloUpdateFacts(versionCode: VersionCode) -> APKFacts {
    APKFacts(
        packageID: helloUpdateID,
        versionCode: versionCode,
        versionName: "\(versionCode).0",
        splitName: nil,
        displayName: "HelloUpdate",
        minSDK: 29,
        targetSDK: 37,
        nativeABIs: ["arm64-v8a"])
}

private func fixtureAPK(_ versionCode: Int) throws -> URL {
    // Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate/<v>/app.apk,
    // found from this file's path (…/Packages/APKStoreCore/Tests/APKStoreCoreTests/).
    let here = URL(fileURLWithPath: #filePath)
    let repo =
        here
        .deletingLastPathComponent()  // APKStoreCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // APKStoreCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("Tests/Fixtures/update-repos/local/io.apkrun.fixture.helloupdate")
    let apk = repo.appendingPathComponent("\(versionCode)/app.apk")
    guard FileManager.default.fileExists(atPath: apk.path) else {
        throw CocoaError(.fileNoSuchFile)
    }
    return apk
}

private func makePolicyStore(at root: URL, versionCode: VersionCode) -> PackageStore {
    PackageStore(
        packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: UpdatePolicyRuntime(channel: UpdatePolicyChannel()),
        inspector: { _ in helloUpdateFacts(versionCode: versionCode) },
        importVerifier: PackageStore.legacyImportVerifier)
}

private func makeTemporaryRoot() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdatePolicyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func updateAuthorityClaimsUpdateOwnershipCases() {
    #expect(UpdateAuthority.apkrun.claimsUpdateOwnership)
    #expect(!UpdateAuthority.googlePlay.claimsUpdateOwnership)
    #expect(!UpdateAuthority.external.claimsUpdateOwnership)
    #expect(UpdateAuthority.manual.claimsUpdateOwnership)
}

@Test func fileImportWithoutProviderGetsManualAuthority() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = makePolicyStore(at: root, versionCode: 1)
    try await store.open()
    let preview = try await store.importPackage(files: [fixtureAPK(1)])
    let record = try await store.installImported(ticket: preview.ticket)

    #expect(record.updateAuthority == .manual)
    #expect(record.updateProvider == nil)
}

@Test func setUpdatePolicyPersistsAcrossReopen() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = makePolicyStore(at: root, versionCode: 1)
    try await store.open()
    let preview = try await store.importPackage(files: [fixtureAPK(1)])
    let record = try await store.installImported(ticket: preview.ticket)

    let provider = UpdateProviderRef(
        type: .local,
        configuration: .local(path: "/tmp/repo", bookmark: "eA=="))
    try await store.setUpdatePolicy(
        for: record.packageId, authority: .apkrun, provider: provider)

    let reopened = makePolicyStore(at: root, versionCode: 1)
    try await reopened.open()
    let reloaded = try #require(
        await reopened.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(reloaded.updateAuthority == .apkrun)
    #expect(reloaded.updateProvider == provider)
}

@Test func setUpdateModeRoundTripsThroughPackageSettings() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = makePolicyStore(at: root, versionCode: 1)
    try await store.open()
    let preview = try await store.importPackage(files: [fixtureAPK(1)])
    let record = try await store.installImported(ticket: preview.ticket)

    try await store.setUpdateMode(for: record.packageId, mode: "notifyOnly")
    let settings = try #require(await store.packageSettings(for: record.packageId))
    #expect(settings.updateMode == "notifyOnly")
}

@Test func stageShowsInRecordAndDiscardStagedRemovesIt() async throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = PackageStore(
        packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: UpdatePolicyRuntime(channel: UpdatePolicyChannel()),
        inspector: { apk in
            // The inspector sees the private copy; the file contents select the
            // facts version.
            let contents = try Data(contentsOf: apk)
            let version: VersionCode = contents == Data("v2 apk bytes".utf8) ? 2 : 1
            return helloUpdateFacts(versionCode: version)
        },
        importVerifier: PackageStore.legacyImportVerifier)
    try await store.open()

    let v1File = root.appendingPathComponent("v1.apk")
    let v2File = root.appendingPathComponent("v2.apk")
    try Data("v1 apk bytes".utf8).write(to: v1File)
    try Data("v2 apk bytes".utf8).write(to: v2File)

    let v1 = try await store.importPackage(files: [v1File])
    let record = try await store.installImported(ticket: v1.ticket)

    let v2 = try await store.importPackage(files: [v2File])
    let setDigest = try ArtifactSet.computeSetDigest(for: v2.artifactSet.files)
    try await store.stage(
        ticket: v2.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2,
            versionName: "2.0",
            setDigest: setDigest,
            size: 2_103_514,
            fileCount: 1,
            origin: ArtifactOrigin(type: .local)))

    let staged = try #require(
        await store.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(staged.artifacts.staged?.versionCode == 2)
    #expect(staged.artifacts.staged?.origin.type == .local)

    // A reopened store keeps the staged slot (crash survival at record level).
    let reopened = PackageStore(
        packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
        runtimeAccess: UpdatePolicyRuntime(channel: UpdatePolicyChannel()),
        inspector: { _ in helloUpdateFacts(versionCode: 1) },
        importVerifier: PackageStore.legacyImportVerifier)
    try await reopened.open()
    let reopenedRecord = try #require(
        await reopened.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(reopenedRecord.artifacts.staged?.versionCode == 2)

    try await reopened.discardStaged(packageID: record.packageId)
    let cleared = try #require(
        await reopened.listManagedPackages().first { $0.packageId == record.packageId })
    #expect(cleared.artifacts.staged == nil)
}
