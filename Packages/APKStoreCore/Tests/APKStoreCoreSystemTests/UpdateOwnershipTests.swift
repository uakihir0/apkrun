import Foundation
import Testing

@testable import APKStoreCore

// T1 of #40 step 2: `request_update_ownership` follows
// `record.updateAuthority.claimsUpdateOwnership && channel.capabilities.contains(.updateOwnership)`
// (package-store.md §6.3), and `android.updateOwner` lands in the record with a
// `store.updateOwnerMissing` health warning when the owner is not io.apkrun.store.

private actor OwnershipChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities
    private var packages: [PackageID: StorePackageInfo] = [:]
    private(set) var requests: [StoreInstallRequest] = []
    private let reportedOwner: PackageID?

    init(capabilities: StoreCapabilities, reportedOwner: PackageID? = nil) {
        self.capabilities = capabilities
        self.reportedOwner = reportedOwner
    }

    func install(_ request: StoreInstallRequest, files _: [URL]) async throws -> StorePackageInfo {
        requests.append(request)
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "HelloUpdate",
            versionCode: request.versionCode,
            enabled: true,
            updateOwner: reportedOwner,
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

private struct OwnershipRuntime: StoreRuntimeAccess {
    let channel: OwnershipChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private func ownershipStore(at packages: URL, channel: OwnershipChannel) -> PackageStore {
    PackageStore(
        packagesDirectory: packages,
        runtimeAccess: OwnershipRuntime(channel: channel),
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
        importVerifier: PackageStore.legacyImportVerifier)
}

private func ownershipRoot() throws -> (root: URL, v1: URL, v2: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("UpdateOwnershipTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Packages", isDirectory: true),
        withIntermediateDirectories: true)
    let v1 = root.appendingPathComponent("v1.apk")
    let v2 = root.appendingPathComponent("v2.apk")
    try Data("v1 apk bytes".utf8).write(to: v1)
    try Data("v2 apk bytes".utf8).write(to: v2)
    return (root, v1, v2)
}

private func installV1(
    store: PackageStore, v1: URL
) async throws -> PackageRecord {
    let preview = try await store.importPackage(files: [v1])
    return try await store.installImported(ticket: preview.ticket)
}

private func stageV2(store: PackageStore, v2: URL) async throws {
    let preview = try await store.importPackage(files: [v2])
    try await store.stage(
        ticket: preview.ticket,
        candidate: StagedUpdateInfo(
            versionCode: 2,
            versionName: "2.0",
            setDigest: try ArtifactSet.computeSetDigest(for: preview.artifactSet.files),
            size: 13,
            fileCount: 1,
            origin: ArtifactOrigin(type: .local)))
}

@Test func firstInstallRequestsOwnershipWhenChannelSupportsIt() async throws {
    let (root, v1, _) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = OwnershipChannel(capabilities: [.install, .metadata, .updateOwnership])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    _ = try await installV1(store: store, v1: v1)

    let request = try #require(await channel.requests.last)
    #expect(request.mode == .new)
    #expect(request.requestUpdateOwnership)
}

@Test func firstInstallDoesNotRequestOwnershipWithoutCapability() async throws {
    let (root, v1, _) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = OwnershipChannel(capabilities: [.install, .metadata])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    _ = try await installV1(store: store, v1: v1)

    let request = try #require(await channel.requests.last)
    #expect(!request.requestUpdateOwnership)
}

@Test(arguments: [UpdateAuthority.googlePlay, .external])
func reinstallSkipsOwnershipForNonClaimingAuthorities(authority: UpdateAuthority) async throws {
    let (root, v1, _) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = OwnershipChannel(capabilities: [.install, .metadata, .updateOwnership])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    let record = try await installV1(store: store, v1: v1)
    try await store.setUpdatePolicy(for: record.packageId, authority: authority)

    let preview = try await store.importPackage(files: [v1])
    _ = try await store.reinstallWithOutcome(ticket: preview.ticket)

    let request = try #require(await channel.requests.last)
    #expect(request.mode == .reinstall)
    #expect(!request.requestUpdateOwnership)
}

@Test func updateRequestsOwnershipForClaimingAuthorities() async throws {
    let (root, v1, v2) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = OwnershipChannel(capabilities: [.install, .metadata, .updateOwnership])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    // A first install lands with the default `manual` authority.
    let record = try await installV1(store: store, v1: v1)
    try await stageV2(store: store, v2: v2)

    _ = try await store.installStaged(for: record.packageId, enableRollback: false) { false }

    let request = try #require(await channel.requests.last)
    #expect(request.mode == .update)
    #expect(request.requestUpdateOwnership)
}

@Test func updateSkipsOwnershipForExternalAuthority() async throws {
    let (root, v1, v2) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = OwnershipChannel(capabilities: [.install, .metadata, .updateOwnership])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    let record = try await installV1(store: store, v1: v1)
    try await store.setUpdatePolicy(for: record.packageId, authority: .external)
    try await stageV2(store: store, v2: v2)

    _ = try await store.installStaged(for: record.packageId, enableRollback: false) { false }

    let request = try #require(await channel.requests.last)
    #expect(request.mode == .update)
    #expect(!request.requestUpdateOwnership)
}

@Test func recordStoresAndroidUpdateOwner() async throws {
    let (root, v1, _) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = PackageStore.updateOwnerPackage
    let channel = OwnershipChannel(
        capabilities: [.install, .metadata, .updateOwnership], reportedOwner: owner)
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    let record = try await installV1(store: store, v1: v1)

    #expect(record.android.updateOwner == owner)
    #expect(try await store.updateOwnerMissingPackages().isEmpty)
}

@Test func updateOwnerMissingCountsClaimingAuthoritiesOnly() async throws {
    let (root, v1, _) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // The channel cannot read or grant ownership (a stock image): the install
    // proceeds, the record keeps updateOwner = nil, and health reports the gap.
    let channel = OwnershipChannel(capabilities: [.install, .metadata])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    let record = try await installV1(store: store, v1: v1)
    #expect(record.android.updateOwner == nil)
    #expect(try await store.updateOwnerMissingPackages() == [record.packageId])

    // `external` does not claim ownership, so the missing owner is not a finding.
    try await store.setUpdatePolicy(for: record.packageId, authority: .external)
    #expect(try await store.updateOwnerMissingPackages().isEmpty)
}
