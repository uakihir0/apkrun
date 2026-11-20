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
    private(set) var relinquishCalls: [PackageID] = []
    private let reportedOwner: PackageID?
    /// Observes the store record's authority while the relinquish call is in flight,
    /// proving the guest call precedes the record write.
    private var authorityDuringRelinquish: (@Sendable () async -> UpdateAuthority?)?
    private(set) var relinquishSawAuthority: UpdateAuthority?

    init(capabilities: StoreCapabilities, reportedOwner: PackageID? = nil) {
        self.capabilities = capabilities
        self.reportedOwner = reportedOwner
    }

    func onRelinquish(_ probe: @escaping @Sendable () async -> UpdateAuthority?) {
        authorityDuringRelinquish = probe
    }

    func relinquishUpdateOwnership(_ package: PackageID) async throws {
        relinquishCalls.append(package)
        if let authorityDuringRelinquish {
            relinquishSawAuthority = await authorityDuringRelinquish()
        }
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

@Test func updateRefusesInstallUnderExternalAuthority() async throws {
    let (root, v1, v2) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = OwnershipChannel(capabilities: [.install, .metadata, .updateOwnership])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    let record = try await installV1(store: store, v1: v1)
    try await stageV2(store: store, v2: v2)
    try await store.setUpdatePolicy(for: record.packageId, authority: .external)

    // §2.1: an externally-owned package's staged update never reaches the
    // Android commit.
    do {
        _ = try await store.installStaged(for: record.packageId, enableRollback: false) { false }
        Issue.record("expected authorityDoesNotAllowUpdates")
    } catch PackageStoreFailure.authorityDoesNotAllowUpdates {
    }
    #expect(await channel.requests.last?.mode != .update)
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

@Test func authorityChangeRelinquishesBeforeRecordWrite() async throws {
    let (root, v1, _) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = OwnershipChannel(capabilities: [.install, .metadata, .updateOwnership])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    let record = try await installV1(store: store, v1: v1)
    await channel.onRelinquish {
        // Read the record on disk directly — the store's mutation lock is held
        // during setUpdateAuthority, so asking the store would deadlock.
        let packages = root.appendingPathComponent("Packages", isDirectory: true)
        let metadata = URL(fileURLWithPath: packages.path)
            .appendingPathComponent("\(record.packageId.rawValue)/metadata.json")
        guard let data = try? Data(contentsOf: metadata) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PackageRecord.self, from: data).updateAuthority
    }

    try await store.setUpdateAuthority(id: record.packageId, authority: .external)

    // The guest call saw the old authority: it ran before the record write.
    #expect(await channel.relinquishCalls == [record.packageId])
    #expect(await channel.relinquishSawAuthority == .manual)
    #expect(try await store.listManagedPackages().first?.updateAuthority == .external)
}

@Test func authorityChangeWithinClaimingSetSkipsRelinquish() async throws {
    let (root, v1, _) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = OwnershipChannel(capabilities: [.install, .metadata, .updateOwnership])
    let store = ownershipStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()

    let record = try await installV1(store: store, v1: v1)
    try await store.setUpdateAuthority(id: record.packageId, authority: .apkrun)

    #expect(await channel.relinquishCalls.isEmpty)
    #expect(try await store.listManagedPackages().first?.updateAuthority == .apkrun)
}

@Test func authorityChangeWithoutRuntimeBecomesPostBootTask() async throws {
    let (root, v1, _) = try ownershipRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let packages = root.appendingPathComponent("Packages", isDirectory: true)

    // Install once with a channel, then reopen without a runtime.
    let seedChannel = OwnershipChannel(capabilities: [.install, .metadata])
    let seedStore = ownershipStore(at: packages, channel: seedChannel)
    try await seedStore.open()
    let record = try await installV1(store: seedStore, v1: v1)

    let offlineStore = PackageStore(
        packagesDirectory: packages,
        runtimeAccess: nil,
        inspector: { _ in
            APKFacts(
                packageID: PackageID(rawValue: "io.apkrun.fixture.helloupdate")!,
                versionCode: 1,
                versionName: "1.0",
                splitName: nil,
                displayName: "HelloUpdate",
                minSDK: 29,
                targetSDK: 37,
                nativeABIs: ["arm64-v8a"])
        },
        importVerifier: PackageStore.legacyImportVerifier)
    try await offlineStore.open()
    try await offlineStore.setUpdateAuthority(id: record.packageId, authority: .external)
    #expect(try await offlineStore.listManagedPackages().first?.updateAuthority == .external)

    // The deferred relinquish replays when a runtime attaches (§5.5 post-boot task).
    let channel = OwnershipChannel(capabilities: [.install, .metadata, .updateOwnership])
    let recoveredStore = ownershipStore(at: packages, channel: channel)
    try await recoveredStore.open()
    #expect(await channel.relinquishCalls == [])
    try await recoveredStore.recoverPendingTransactions()
    #expect(await channel.relinquishCalls == [record.packageId])
}
