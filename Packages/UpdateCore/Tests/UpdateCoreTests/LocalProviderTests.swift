import APKStoreCore
import Foundation
import Testing

@testable import UpdateCore

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

private func makeContext(root: URL) -> ProviderContext {
    ProviderContext(
        http: FailingHTTP(),
        cache: MemoryCache(root: root.appendingPathComponent("cache")),
        credentials: NoCredentials(),
        userInitiated: true)
}

private func makePackage(
    _ id: String,
    versionCode: VersionCode,
    cursor: ProviderCursor? = nil
) throws -> InstalledPackage {
    InstalledPackage(
        id: try #require(PackageID(rawValue: id)),
        versionCode: versionCode,
        signerDigests: [],
        lineage: [],
        guest: GuestFacts(),
        lastCursor: cursor)
}

private func makeProvider(at root: URL) -> LocalProvider {
    LocalProvider(
        ref: UpdateProviderRef(
            type: .local,
            configuration: .local(path: root.path, bookmark: "eA==")),
        root: root,
        displayPath: root.path)
}

private func writeFile(_ data: Data = Data([1, 2, 3]), at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

@Test func localProviderPicksHighestNumericDirectoryAboveInstalled() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-local-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = "com.example.app"
    try writeFile(at: root.appendingPathComponent("\(package)/1/app.apk"))
    try writeFile(at: root.appendingPathComponent("\(package)/3/app.apk"))
    try writeFile(at: root.appendingPathComponent("\(package)/2/app.apk"))
    // Non-numeric and zero directories are never candidates.
    try writeFile(at: root.appendingPathComponent("\(package)/latest/app.apk"))
    try writeFile(at: root.appendingPathComponent("\(package)/0/app.apk"))

    let provider = makeProvider(at: root)
    let installed = try makePackage(package, versionCode: 1)
    let candidate = try await provider.check(installed, context: makeContext(root: root))

    #expect(candidate?.declaredVersionCode == 3)
    #expect(candidate?.cursor.type == .local)
    #expect(candidate?.artifacts.count == 1)
    #expect(candidate?.artifacts.first?.kind == .apk)
}

@Test func localProviderReportsUpToDateWhenNothingIsNewer() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-local-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = "com.example.app"
    try writeFile(at: root.appendingPathComponent("\(package)/1/app.apk"))
    try writeFile(at: root.appendingPathComponent("\(package)/0/app.apk"))

    let provider = makeProvider(at: root)
    #expect(
        try await provider.check(
            makePackage(package, versionCode: 1), context: makeContext(root: root)) == nil)
    // A package the repository does not carry is not an error.
    #expect(
        try await provider.check(
            makePackage("com.other.app", versionCode: 1), context: makeContext(root: root)) == nil)
}

@Test func localProviderSkipsReleaseMatchingSavedCursor() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-local-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = "com.example.app"
    try writeFile(at: root.appendingPathComponent("\(package)/2/app.apk"))

    let provider = makeProvider(at: root)
    let context = makeContext(root: root)
    let installed = try makePackage(package, versionCode: 1)
    let candidate = try #require(await provider.check(installed, context: context))

    let again = try await provider.check(
        makePackage(package, versionCode: 1, cursor: candidate.cursor),
        context: context)
    #expect(again == nil)
}

@Test func localProviderAcceptsSplitAndContainerLayouts() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-local-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let splits = "com.example.splits"
    try writeFile(at: root.appendingPathComponent("\(splits)/2/base.apk"))
    try writeFile(at: root.appendingPathComponent("\(splits)/2/split_feature.apk"))
    try writeFile(at: root.appendingPathComponent("\(splits)/2/split_config.arm64_v8a.apk"))
    let provider = makeProvider(at: root)
    let splitCandidate = try #require(
        await provider.check(
            makePackage(splits, versionCode: 1), context: makeContext(root: root)))
    #expect(
        splitCandidate.artifacts.map(\.kind) == [
            .apk, .split("config.arm64_v8a"), .split("feature"),
        ])

    let container = "com.example.container"
    try writeFile(at: root.appendingPathComponent("\(container)/2/app.apks"))
    let containerCandidate = try #require(
        await provider.check(
            makePackage(container, versionCode: 1), context: makeContext(root: root)))
    #expect(containerCandidate.artifacts.map(\.kind) == [.container])
}

@Test func localProviderRejectsUnrecognizedLayout() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-local-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = "com.example.app"
    try writeFile(at: root.appendingPathComponent("\(package)/2/random.apk"))
    try writeFile(Data("notes".utf8), at: root.appendingPathComponent("\(package)/2/readme.txt"))

    let provider = makeProvider(at: root)
    await #expect(
        throws: UpdateFailure.providerMetadataInvalid(detail: "version directory holds no recognized APK layout")
    ) {
        _ = try await provider.check(
            makePackage(package, versionCode: 1), context: makeContext(root: root))
    }
}

@Test func localProviderCopiesArtifactsOnDownload() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-local-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let package = "com.example.app"
    try writeFile(Data([9, 9, 9, 9]), at: root.appendingPathComponent("\(package)/2/app.apk"))

    let provider = makeProvider(at: root)
    let installed = try makePackage(package, versionCode: 1)
    let candidate = try #require(await provider.check(installed, context: makeContext(root: root)))

    let incoming = root.appendingPathComponent("incoming/ticket", isDirectory: true)
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    final class ProgressLog: @unchecked Sendable {
        var items: [DownloadProgress] = []
    }
    let log = ProgressLog()
    let artifact = try await provider.download(
        candidate,
        to: DownloadDestination(ticket: UUID(), directory: incoming),
        context: makeContext(root: root)
    ) { log.items.append($0) }

    guard case .apk(let url) = artifact else {
        Issue.record("expected .apk, got \(artifact)")
        return
    }
    #expect(url.path.hasPrefix(incoming.path))
    #expect(try Data(contentsOf: url) == Data([9, 9, 9, 9]))
    #expect(log.items.last?.bytesWritten == 4)
}

@Test func providerRegistryParsesLocalSpec() throws {
    let bookmark = Data([1, 2, 3])
    let ref = try ProviderRegistry.parse(
        "local:/Users/test/repo", bookmark: bookmark, developerModeEnabled: true)
    #expect(ref.type == .local)
    guard case .local(let path, let storedBookmark) = ref.configuration else {
        Issue.record("expected .local configuration")
        return
    }
    #expect(path == "/Users/test/repo")
    #expect(storedBookmark == bookmark.base64EncodedString())
}

@Test func providerRegistryGatesLocalOnDeveloperMode() {
    #expect(throws: UpdateFailure.providerNotConfigured) {
        _ = try ProviderRegistry.parse(
            "local:/tmp/repo", bookmark: Data([1]), developerModeEnabled: false)
    }
    #expect(throws: UpdateFailure.providerMetadataInvalid(detail: "local provider needs a security-scoped bookmark")) {
        _ = try ProviderRegistry.parse(
            "local:/tmp/repo", bookmark: nil, developerModeEnabled: true)
    }
    #expect(throws: UpdateFailure.providerMetadataInvalid(detail: "unknown provider spec")) {
        _ = try ProviderRegistry.parse(
            "not-a-spec", bookmark: nil, developerModeEnabled: true)
    }
}

@Test func providerRegistryParsesDirectSpec() throws {
    let ref = try ProviderRegistry.parse(
        "direct:https://example.org/m.json", developerModeEnabled: false)
    #expect(ref.type == .direct)
    guard case .direct(let url) = ref.configuration else {
        Issue.record("expected .direct configuration")
        return
    }
    #expect(url == "https://example.org/m.json")
    #expect(throws: UpdateFailure.providerMetadataInvalid(detail: "direct provider needs a URL")) {
        _ = try ProviderRegistry.parse(
            "direct:https://", developerModeEnabled: false)
    }
    #expect(throws: UpdateFailure.providerMetadataInvalid(detail: "direct provider URL must be https")) {
        _ = try ProviderRegistry.parse(
            "direct:ftp://example.org/m", developerModeEnabled: false)
    }
    #if DEBUG
        let loopback = try ProviderRegistry.parse(
            "direct:http://127.0.0.1:8080/m.json", developerModeEnabled: false)
        #expect(loopback.type == .direct)
    #endif
}
