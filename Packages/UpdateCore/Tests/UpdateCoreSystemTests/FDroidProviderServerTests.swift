import APKStoreCore
import Foundation
import Testing

@testable import UpdateCore

// T1 of #52: FDroidProvider over real loopback HTTP against
// scripts/dev/update-server.py serving the committed fixture repository
// (update-system.md §4.5).

private let fdroidTestFingerprint =
    "867322208466d85ddf20f8bd8a946a7f39fc84754cf801ff92ecdd18457f695a"
private let fdroidSignerA =
    "a2f3893391ae70e6faee50a05c0d0c4b94505781f7af0d547c1625399e05f8b4"
private let fdroidPackageID = "io.apkrun.fixture.helloupdate"

/// The committed `update-repos/` fixture root — `update-server.py --root`.
func updateReposRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/update-repos")
        .standardizedFileURL
}

private struct FDroidMemoryCache: ProviderCache {
    let root: URL
    func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct FDroidNoCredentials: ProviderCredentials {
    func token(for _: String) -> String? { nil }
    func setToken(_: String?, for _: String) throws {}
}

private func fdroidContext(
    root: URL, note: FDroidNoteBox = FDroidNoteBox()
) -> ProviderContext {
    ProviderContext(
        http: URLSessionUpdateHTTPClient(),
        cache: FDroidMemoryCache(root: root),
        credentials: FDroidNoCredentials(),
        incompatibleNote: { note.reasons.append($0) })
}

final class FDroidNoteBox: @unchecked Sendable {
    var reasons: [NoCompatibleArtifactReason] = []
}

private func fdroidProvider(_ server: UpdateServer) throws -> FDroidProvider {
    let repo = "\(server.baseURL.absoluteString)/fdroid/repo"
    return try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(fdroidTestFingerprint)"))
}

private func installedHelloupdate(
    versionCode: VersionCode = 1, signer: String = fdroidSignerA
) throws -> InstalledPackage {
    InstalledPackage(
        id: try #require(PackageID(rawValue: fdroidPackageID)),
        versionCode: versionCode,
        signerDigests: [
            try #require(SHA256Digest(rawValue: "sha256:\(signer)"))
        ],
        lineage: [],
        guest: GuestFacts(sdk: 37, abis: ["arm64-v8a"]),
        lastCursor: nil)
}

@Test func fdroidCheckFindsV2OverLoopback() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let checked = try await fdroidProvider(server).check(
        installedHelloupdate(),
        context: fdroidContext(root: server.root))
    let candidate = try #require(checked)
    #expect(candidate.declaredVersionCode == 2)
    #expect(candidate.cursor.type == .fdroid)
}

@Test func fdroidCheckSeedsOldCacheThenAppliesTheDiff() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let provider = try fdroidProvider(server)
    // Seed the provider cache with index-v2-old.json at the diff's base ts.
    let cacheDir = try FDroidMemoryCache(root: server.root).directory(
        forKey: provider.cacheKey)
    let repoDir = updateReposRoot().appendingPathComponent("fdroid/repo")
    try Data(contentsOf: repoDir.appendingPathComponent("index-v2-old.json"))
        .write(to: cacheDir.appendingPathComponent("index.json"))
    try Data(
        "{\"timestamp\":1700000000000,\"sha256\":\"x\"}".utf8
    ).write(to: cacheDir.appendingPathComponent("index.meta.json"))

    let checked = try await provider.check(
        installedHelloupdate(),
        context: fdroidContext(root: server.root))
    #expect(checked?.declaredVersionCode == 2)
}

@Test func fdroidCheckRefusesAMismatchedIndex() async throws {
    // Serve a root where index-v2.json is corrupted but entry.jar is the
    // committed (correctly signed) one.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-mismatch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("fdroid/repo"), withIntermediateDirectories: true)
    let fixture = updateReposRoot().appendingPathComponent("fdroid/repo")
    for name in ["entry.jar"] {
        try FileManager.default.copyItem(
            at: fixture.appendingPathComponent(name),
            to: root.appendingPathComponent("fdroid/repo/\(name)"))
    }
    try Data("{\"packages\":{}}".utf8).write(
        to: root.appendingPathComponent("fdroid/repo/index-v2.json"))
    let server = try UpdateServer.start(root: root)
    do {
        _ = try await fdroidProvider(server).check(
            installedHelloupdate(),
            context: fdroidContext(root: server.root))
        Issue.record("expected providerMetadataInvalid")
    } catch let failure as UpdateFailure {
        guard case .providerMetadataInvalid = failure else {
            Issue.record("expected providerMetadataInvalid, got \(failure)")
            return
        }
    }
}

@Test func fdroidCheckRefusesAWrongFingerprint() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let repo = "\(server.baseURL.absoluteString)/fdroid/repo"
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(
            for: "\(repo)#\(String(repeating: "d", count: 64))"))
    do {
        _ = try await provider.check(
            installedHelloupdate(),
            context: fdroidContext(root: server.root))
        Issue.record("expected providerSignatureInvalid")
    } catch let failure as UpdateFailure {
        guard case .providerSignatureInvalid = failure else {
            Issue.record("expected providerSignatureInvalid, got \(failure)")
            return
        }
    }
}

@Test func fdroidCheckRefusesATamperedEntry() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-tampered-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("fdroid/repo"), withIntermediateDirectories: true)
    let fixture = updateReposRoot().appendingPathComponent("fdroid/repo")
    try FileManager.default.copyItem(
        at: fixture.appendingPathComponent("entry-tampered.jar"),
        to: root.appendingPathComponent("fdroid/repo/entry.jar"))
    let server = try UpdateServer.start(root: root)
    do {
        _ = try await fdroidProvider(server).check(
            installedHelloupdate(),
            context: fdroidContext(root: server.root))
        Issue.record("expected providerSignatureInvalid")
    } catch let failure as UpdateFailure {
        guard case .providerSignatureInvalid = failure else {
            Issue.record("expected providerSignatureInvalid, got \(failure)")
            return
        }
    }
}

@Test func fdroidCheckReportsSignerDiffersOverLoopback() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let note = FDroidNoteBox()
    // versionCode 2 → only the version-3 (other-signer) entry is a newer
    // candidate, and its signer never matches "cc…".
    let checked = try await fdroidProvider(server).check(
        installedHelloupdate(
            versionCode: 2, signer: String(repeating: "c", count: 64)),
        context: fdroidContext(root: server.root, note: note))
    #expect(checked == nil)
    #expect(note.reasons == [.signerDiffers])
}

@Test func fdroidDownloadFetchesTheAPKOverLoopback() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let provider = try fdroidProvider(server)
    let context = fdroidContext(root: server.root)
    guard
        let candidate = try await provider.check(
            installedHelloupdate(), context: context)
    else {
        Issue.record("no candidate")
        return
    }
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: destination, withIntermediateDirectories: true)
    let artifact = try await provider.download(
        candidate,
        to: DownloadDestination(ticket: UUID(), directory: destination),
        context: context
    ) { _ in }
    guard case .apk(let file) = artifact else {
        Issue.record("expected an .apk artifact")
        return
    }
    let expected = try Data(
        contentsOf: updateReposRoot()
            .appendingPathComponent(
                "fdroid/repo/io.apkrun.fixture.helloupdate_2.apk"))
    #expect(try Data(contentsOf: file) == expected)
}
