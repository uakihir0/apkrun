import Foundation
import Testing

@testable import APKStoreCore

// T0 of #39 step 5: ImportRelation classification (package-store.md §4.7) and
// the install-time refusals for otherSigner/downgrade before any Android call.

private actor ImportRelationChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities = [.install, .metadata]
    private var packages: [PackageID: StorePackageInfo] = [:]
    private(set) var installCalls = 0
    private(set) var androidCalls = 0

    func install(_ request: StoreInstallRequest, files _: [URL]) async throws -> StorePackageInfo {
        installCalls += 1
        androidCalls += 1
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "HelloUpdate",
            versionCode: request.versionCode,
            enabled: true,
            targetSDK: 37,
            minSDK: 29,
            signingDigests: request.signerDigests)
        packages[request.packageID] = info
        return info
    }

    func uninstall(_ package: PackageID, keepData _: Bool) async throws {
        androidCalls += 1
        packages[package] = nil
    }

    func packageInfo(_ package: PackageID) async throws -> StorePackageInfo? {
        androidCalls += 1
        return packages[package]
    }

    func listPackages(_: StorePackageFilter) async throws -> [StorePackageSummary] {
        []
    }
}

private struct ImportRelationRuntime: StoreRuntimeAccess {
    let channel: ImportRelationChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

/// The signer the next import verification reports, so tests can simulate a
/// candidate signed by the same or a different key without real signatures.
private final class SignerKnob: @unchecked Sendable {
    private let lock = NSLock()
    private var digests: [SHA256Digest] = []

    var value: [SHA256Digest] {
        lock.lock()
        defer { lock.unlock() }
        return digests
    }

    func set(_ digests: [SHA256Digest]) {
        lock.lock()
        self.digests = digests
        lock.unlock()
    }
}

private let relationPackageID = PackageID(rawValue: "io.apkrun.fixture.helloupdate")!

private func relationFacts(versionCode: VersionCode) -> APKFacts {
    APKFacts(
        packageID: relationPackageID,
        versionCode: versionCode,
        versionName: "\(versionCode).0",
        splitName: nil,
        displayName: "HelloUpdate",
        minSDK: 29,
        targetSDK: 37,
        nativeABIs: ["arm64-v8a"])
}

private func relationAPK(at root: URL, versionCode: Int, bytes: String = "apk bytes") throws -> URL {
    let apk = root.appendingPathComponent("app-v\(versionCode)-\(bytes.count).apk")
    try Data("version \(versionCode) \(bytes)".utf8).write(to: apk)
    return apk
}

private func signerDigest(_ tag: String) -> SHA256Digest {
    SHA256Digest(data: Data(tag.utf8))
}

/// The version embedded in a fixture file's contents (`version <N> …`), so the
/// fake inspector reports a different versionCode per file even after the
/// store stages it under a different name.
private func fixtureVersion(of url: URL) -> VersionCode {
    guard let contents = try? Data(contentsOf: url),
        let text = String(data: contents, encoding: .utf8),
        text.hasPrefix("version "),
        let version = VersionCode(text.dropFirst(8).split(separator: " ").first ?? "")
    else { return 1 }
    return version
}

private final class RelationFixture {
    let root: URL
    let channel = ImportRelationChannel()
    let signers = SignerKnob()
    init() throws {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportRelationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeStore() -> PackageStore {
        let signers = self.signers
        return PackageStore(
            packagesDirectory: root.appendingPathComponent("Packages", isDirectory: true),
            runtimeAccess: ImportRelationRuntime(channel: channel),
            inspector: { url in relationFacts(versionCode: fixtureVersion(of: url)) },
            importVerifier: { staged, _, inspect in
                var facts: [APKFacts] = []
                for stagedURL in staged {
                    facts.append(try await inspect(stagedURL))
                }
                return PackageStore.VerifiedImport(
                    files: staged,
                    facts: facts,
                    signerDigests: signers.value,
                    lineage: [],
                    warnings: [],
                    excludedSplits: [])
            })
    }
}

/// Installs `versionCode` signed by `signer`, returning the open store.
private func installedStore(
    at fixture: RelationFixture,
    versionCode: VersionCode,
    signer: String
) async throws -> PackageStore {
    fixture.signers.set([signerDigest(signer)])
    let store = fixture.makeStore()
    try await store.open()
    let preview = try await store.importPackage(
        files: [try relationAPK(at: fixture.root, versionCode: Int(versionCode))])
    _ = try await store.installImported(ticket: preview.ticket)
    await fixture.channel.resetAndroidCalls()
    return store
}

extension ImportRelationChannel {
    func resetAndroidCalls() {
        installCalls = 0
        androidCalls = 0
    }
}

@Test func importRelationNewPackageWhenNoRecordExists() async throws {
    let fixture = try RelationFixture()
    let store = fixture.makeStore()
    try await store.open()
    let preview = try await store.importPackage(
        files: [try relationAPK(at: fixture.root, versionCode: 1)])
    #expect(preview.relation == .newPackage)
}

@Test func importRelationUpdateWhenVersionCodeIncreases() async throws {
    let fixture = try RelationFixture()
    let store = try await installedStore(at: fixture, versionCode: 1, signer: "a")
    let preview = try await store.importPackage(
        files: [try relationAPK(at: fixture.root, versionCode: 2)])
    #expect(preview.relation == .update(from: 1))
}

@Test func importRelationDowngradeWhenVersionCodeDecreases() async throws {
    let fixture = try RelationFixture()
    let store = try await installedStore(at: fixture, versionCode: 2, signer: "a")
    let preview = try await store.importPackage(
        files: [try relationAPK(at: fixture.root, versionCode: 1)])
    #expect(preview.relation == .downgrade(from: 2))
}

@Test func importRelationSameAsInstalledForIdenticalSet() async throws {
    let fixture = try RelationFixture()
    let store = fixture.makeStore()
    try await store.open()
    fixture.signers.set([signerDigest("a")])
    let apk = try relationAPK(at: fixture.root, versionCode: 1)
    let preview = try await store.importPackage(files: [apk])
    _ = try await store.installImported(ticket: preview.ticket)
    let reimport = try await store.importPackage(files: [apk])
    #expect(reimport.relation == .sameAsInstalled)
}

@Test func importRelationReinstallSameVersionForDifferentSet() async throws {
    let fixture = try RelationFixture()
    let store = try await installedStore(at: fixture, versionCode: 1, signer: "a")
    let other = try relationAPK(at: fixture.root, versionCode: 1, bytes: "different apk bytes")
    let preview = try await store.importPackage(files: [other])
    #expect(preview.relation == .reinstallSameVersion)
}

@Test func importRelationOtherSignerForDifferentKey() async throws {
    let fixture = try RelationFixture()
    let store = try await installedStore(at: fixture, versionCode: 1, signer: "a")
    fixture.signers.set([signerDigest("b")])
    let preview = try await store.importPackage(
        files: [try relationAPK(at: fixture.root, versionCode: 2)])
    #expect(preview.relation == .otherSigner)
}

@Test func importRelationUninstalledWithDataAfterKeptUninstall() async throws {
    let fixture = try RelationFixture()
    let store = try await installedStore(at: fixture, versionCode: 1, signer: "a")
    try await store.uninstall(packageID: relationPackageID, keepData: true)
    let preview = try await store.importPackage(
        files: [try relationAPK(at: fixture.root, versionCode: 1)])
    #expect(preview.relation == .uninstalledWithData(1))
}

@Test func installImportedRefusesOtherSignerBeforeAnyAndroidCall() async throws {
    let fixture = try RelationFixture()
    let store = try await installedStore(at: fixture, versionCode: 1, signer: "a")
    fixture.signers.set([signerDigest("b")])
    let preview = try await store.importPackage(
        files: [try relationAPK(at: fixture.root, versionCode: 2)])
    #expect(preview.relation == .otherSigner)
    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("A different-signer candidate must be refused.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .signerMismatch(relationPackageID))
    }
    #expect(await fixture.channel.installCalls == 0)
    #expect(await fixture.channel.androidCalls == 0)
}

@Test func installImportedRefusesDowngradeBeforeInstallCall() async throws {
    let fixture = try RelationFixture()
    let store = try await installedStore(at: fixture, versionCode: 2, signer: "a")
    let preview = try await store.importPackage(
        files: [try relationAPK(at: fixture.root, versionCode: 1)])
    #expect(preview.relation == .downgrade(from: 2))
    do {
        _ = try await store.installImported(ticket: preview.ticket)
        Issue.record("A downgrade must be refused.")
    } catch let failure as PackageStoreFailure {
        #expect(failure == .downgradeRefused(installed: 2, candidate: 1))
    }
    #expect(await fixture.channel.installCalls == 0)
}
