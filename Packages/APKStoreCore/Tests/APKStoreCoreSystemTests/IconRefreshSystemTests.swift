import Foundation
import Testing

@testable import APKStoreCore

private actor IconChannel: StoreAgentChannel {
    nonisolated let capabilities: StoreCapabilities
    private var packages: [PackageID: StorePackageInfo] = [:]
    private(set) var renderCalls: [PackageID] = []
    var icon: StoreIcon

    init(capabilities: StoreCapabilities, icon: StoreIcon) {
        self.capabilities = capabilities
        self.icon = icon
    }

    func setIcon(_ icon: StoreIcon) {
        self.icon = icon
    }

    func install(_ request: StoreInstallRequest, files _: [URL]) async throws -> StorePackageInfo {
        let info = StorePackageInfo(
            packageID: request.packageID,
            displayName: "HelloIcon",
            versionCode: request.versionCode,
            enabled: true,
            updateOwner: nil,
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

    func renderIcon(_ package: PackageID, sizePx _: Int) async throws -> StoreIcon? {
        renderCalls.append(package)
        return icon
    }
}

private struct IconRuntime: StoreRuntimeAccess {
    let channel: IconChannel

    func withStoreAgent<T: Sendable>(
        _: UUID,
        _ body: @Sendable (any StoreAgentChannel) async throws -> T
    ) async throws -> T {
        try await body(channel)
    }

    func userdataGeneration() async -> UUID? { nil }
}

private final class IconChangeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [PackageID] = []

    func record(_ packageID: PackageID) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(packageID)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }
}

private func iconStore(at packages: URL, channel: IconChannel) -> PackageStore {
    PackageStore(
        packagesDirectory: packages,
        runtimeAccess: IconRuntime(channel: channel),
        inspector: { _ in
            APKFacts(
                packageID: PackageID(rawValue: "io.apkrun.fixture.helloicon")!,
                versionCode: 1,
                versionName: "1.0",
                splitName: nil,
                displayName: "HelloIcon",
                minSDK: 29,
                targetSDK: 37,
                nativeABIs: ["arm64-v8a"])
        },
        importVerifier: PackageStore.legacyImportVerifier)
}

private func iconRoot() throws -> (root: URL, apk: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("IconRefreshTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Packages", isDirectory: true),
        withIntermediateDirectories: true)
    let apk = root.appendingPathComponent("v1.apk")
    try Data("v1 apk bytes".utf8).write(to: apk)
    return (root, apk)
}

private let helloPackage = PackageID(rawValue: "io.apkrun.fixture.helloicon")!

private func adaptiveIcon(seed: UInt8) -> StoreIcon {
    StoreIcon(
        kind: .adaptive,
        layers: [
            StoreIconLayer(role: .background, png: Data([seed, 1])),
            StoreIconLayer(role: .foreground, png: Data([seed, 2])),
            StoreIconLayer(role: .monochrome, png: Data([seed, 3])),
        ])
}

/// package-store.md §10.2: an install renders the icon into `icon/` and reports
/// `iconChanged` only when the set digest differs.
@Test func installRendersIconLayersAndWritesManifest() async throws {
    let (root, apk) = try iconRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = IconChannel(
        capabilities: [.install, .metadata, .icons], icon: adaptiveIcon(seed: 7))
    let store = iconStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()
    let probe = IconChangeProbe()
    await store.setIconChangeHandler { probe.record($0) }

    let preview = try await store.importPackage(files: [apk])
    let record = try await store.installImported(ticket: preview.ticket)

    #expect(await channel.renderCalls == [helloPackage])
    #expect(probe.count == 1)
    let iconDir = try #require(await store.iconDirectory(for: record.packageId))
    #expect(FileManager.default.fileExists(
        atPath: iconDir.appendingPathComponent("background.png").path))
    #expect(FileManager.default.fileExists(
        atPath: iconDir.appendingPathComponent("monochrome.png").path))
    let manifest = await store.iconManifest(for: record.packageId)
    #expect(manifest?.kind == .adaptive)
    #expect(manifest?.sizePx == 1536)
    #expect(manifest?.renderedForVersionCode == 1)
}

@Test func unchangedIconSetDoesNotReportIconChanged() async throws {
    let (root, apk) = try iconRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = IconChannel(
        capabilities: [.install, .metadata, .icons], icon: adaptiveIcon(seed: 7))
    let store = iconStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()
    let preview = try await store.importPackage(files: [apk])
    _ = try await store.installImported(ticket: preview.ticket)

    let probe = IconChangeProbe()
    await store.setIconChangeHandler { probe.record($0) }
    let changed = try await store.refreshRenderedIcon(helloPackage, renderedForVersionCode: 1)
    #expect(!changed)
    #expect(probe.count == 0)

    await channel.setIcon(adaptiveIcon(seed: 9))
    let changedAgain = try await store.refreshRenderedIcon(helloPackage, renderedForVersionCode: 1)
    #expect(changedAgain)
    #expect(probe.calls == [helloPackage])
}

@Test func channelWithoutIconsLeavesIconDirectoryAbsent() async throws {
    let (root, apk) = try iconRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let channel = IconChannel(
        capabilities: [.install, .metadata], icon: adaptiveIcon(seed: 7))
    let store = iconStore(
        at: root.appendingPathComponent("Packages", isDirectory: true), channel: channel)
    try await store.open()
    let preview = try await store.importPackage(files: [apk])
    let record = try await store.installImported(ticket: preview.ticket)

    #expect(await channel.renderCalls.isEmpty)
    #expect(await store.iconManifest(for: record.packageId) == nil)
}
