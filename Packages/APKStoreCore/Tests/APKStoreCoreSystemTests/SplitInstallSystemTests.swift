import Foundation
import Testing

@testable import APKStoreCore

// T1 of #43: a split set reaches the store channel once, with every artifact in
// one session — install, reinstall, and update alike (package-store.md §6.4,
// guest-protocol.md §11.3).

private struct ChannelFailure: Error {}

private actor RecordingChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities = [.install, .metadata, .rollback]

    struct InstallCall: Sendable {
        var request: StoreInstallRequest
        var fileNames: [String]
    }

    private(set) var installCalls: [InstallCall] = []
    private var failure: Error?

    func setFailure(_ error: Error?) { failure = error }

    func install(_ request: StoreInstallRequest, files: [URL]) async throws -> StorePackageInfo {
        installCalls.append(InstallCall(request: request, fileNames: files.map(\.lastPathComponent)))
        if let failure { throw failure }
        return StorePackageInfo(
            packageID: request.packageID,
            displayName: "HelloSplit",
            versionCode: request.versionCode,
            enabled: true,
            targetSDK: 37,
            minSDK: 32)
    }

    func uninstall(_: PackageID, keepData _: Bool) async throws {}
    func packageInfo(_: PackageID) async throws -> StorePackageInfo? { nil }
    func listPackages(_: StorePackageFilter) async throws -> [StorePackageSummary] { [] }
}

private struct RecordingRuntime: StoreRuntimeAccess {
    let channel: RecordingChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private let splitPackageID = PackageID(rawValue: "io.apkrun.fixture.hellosplit")!

/// Synthetic split facts from a `v<version>|<splitName>` content marker.
private func splitInspector(_ apk: URL) throws -> APKFacts {
    let marker = String(decoding: try Data(contentsOf: apk), as: UTF8.self)
    let parts = marker.split(separator: "|", maxSplits: 1)
    let version = Int64(parts[0].dropFirst()) ?? 1
    let splitName = parts.count > 1 ? String(parts[1]) : nil
    return APKFacts(
        packageID: splitPackageID,
        versionCode: version,
        versionName: "\(version).0",
        splitName: splitName == "base" ? nil : splitName,
        displayName: "HelloSplit",
        minSDK: 32,
        targetSDK: 37,
        nativeABIs: ["arm64-v8a"],
        isFeatureSplit: splitName == "feature")
}

private func writeSplitSet(
    _ names: [String], version: Int, into directory: URL
) throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try names.map { name in
        let url = directory.appendingPathComponent("src-\(name)")
        try "v\(version)|\(name)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private func makeStore(at packages: URL, channel: RecordingChannel) -> PackageStore {
    PackageStore(
        packagesDirectory: packages,
        runtimeAccess: RecordingRuntime(channel: channel),
        inspector: splitInspector,
        hostFreeSpace: { _ in Int64.max },
        importVerifier: PackageStore.legacyImportVerifier)
}

private let splitNames = [
    "base", "config.arm64_v8a", "config.ja", "config.xhdpi", "feature",
]

private let storedOrder = [
    "base.apk",
    "split_config.arm64_v8a.apk",
    "split_config.ja.apk",
    "split_config.xhdpi.apk",
    "split_feature.apk",
]

@Test(.timeLimit(.minutes(1)))
func installSendsEverySplitInOneChannelSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let channel = RecordingChannel()
    let store = makeStore(at: root.appendingPathComponent("packages"), channel: channel)
    try await store.open()

    // Source order on purpose does not match the stored order; the install
    // contract sorts base first anyway.
    let files = try writeSplitSet(
        ["feature", "config.ja", "base", "config.xhdpi", "config.arm64_v8a"],
        version: 1, into: root)
    let preview = try await store.importPackage(files: files)
    #expect(preview.excludedSplits == [])
    #expect(preview.artifactSet.files.map(\.name) == storedOrder)

    _ = try await store.installImported(ticket: preview.ticket)

    let calls = await channel.installCalls
    #expect(calls.count == 1)
    #expect(calls[0].fileNames == storedOrder)
    #expect(calls[0].request.mode == .new)
}

@Test(.timeLimit(.minutes(1)))
func reinstallSendsTheFullSetAgainInOneSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let channel = RecordingChannel()
    let store = makeStore(at: root.appendingPathComponent("packages"), channel: channel)
    try await store.open()

    let files = try writeSplitSet(splitNames, version: 1, into: root)
    let preview = try await store.importPackage(files: files)
    _ = try await store.installImported(ticket: preview.ticket)

    // A same-set re-import is a reinstall (§4.7); the ticket carries the full set.
    let again = try await store.importPackage(files: files)
    _ = try await store.reinstall(ticket: again.ticket)

    let calls = await channel.installCalls
    #expect(calls.count == 2)
    #expect(calls[1].fileNames == storedOrder)
    #expect(calls[1].request.mode == .reinstall)
}

@Test(.timeLimit(.minutes(1)))
func stagedUpdateSendsTheFullSetInOneSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let channel = RecordingChannel()
    let store = makeStore(at: root.appendingPathComponent("packages"), channel: channel)
    try await store.open()

    let v1 = try writeSplitSet(splitNames, version: 1, into: root.appendingPathComponent("v1", isDirectory: true))
    let previewV1 = try await store.importPackage(files: v1)
    _ = try await store.installImported(ticket: previewV1.ticket)

    let v2dir = root.appendingPathComponent("v2", isDirectory: true)
    try FileManager.default.createDirectory(at: v2dir, withIntermediateDirectories: true)
    let v2 = try writeSplitSet(splitNames, version: 2, into: v2dir)
    let previewV2 = try await store.importPackage(files: v2)
    let set = previewV2.artifactSet
    try await store.stage(
        ticket: previewV2.ticket,
        candidate: StagedUpdateInfo(
            versionCode: set.versionCode,
            versionName: set.versionName,
            setDigest: set.setDigest,
            size: set.files.reduce(0) { $0 + $1.size },
            fileCount: set.files.count,
            origin: ArtifactOrigin(type: .manualFile)))

    _ = try await store.installStaged(
        for: splitPackageID, enableRollback: false, hasOpenSession: { false })

    let calls = await channel.installCalls
    #expect(calls.count == 2)
    #expect(calls[1].fileNames == storedOrder)
    #expect(calls[1].request.mode == .update)

    // current/ holds every staged file after the commit (§5.2).
    let current = root.appendingPathComponent("packages/io.apkrun.fixture.hellosplit/current")
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: current.path)
            .filter { $0.hasSuffix(".apk") }.sorted() == storedOrder)
}

@Test(.timeLimit(.minutes(1)))
func aRejectedSplitAbortsTheWholeSession() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let channel = RecordingChannel()
    await channel.setFailure(ChannelFailure())
    let store = makeStore(at: root.appendingPathComponent("packages"), channel: channel)
    try await store.open()

    let files = try writeSplitSet(splitNames, version: 1, into: root)
    let preview = try await store.importPackage(files: files)
    await #expect(throws: ChannelFailure.self) {
        try await store.installImported(ticket: preview.ticket)
    }

    // One call carried the whole set; nothing installed (§11.3: a hash mismatch
    // on one split aborts all).
    #expect(await channel.installCalls.count == 1)
    let info = try await store.installedPackageInfo(splitPackageID)
    #expect(info == nil)
}
