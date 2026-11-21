import APKStoreCore
import Foundation
import RuntimeAPI
import Testing

@testable import UpdateCore

/// File-serving HTTP client pointed at the committed fixture repository.
private struct FixtureHTTP: UpdateHTTPClient {
    let root: URL
    let recorded = Recorded()
    /// Bodies that replace the file payload, for failure cases.
    var overrides: [String: Data] = [:]
    /// Per-URL status answers.
    var statuses: [String: Int] = [:]

    final class Recorded: @unchecked Sendable {
        var requests: [URL] = []
    }

    private func body(for url: URL) throws(UpdateFailure) -> Data {
        let name = url.lastPathComponent
        if let data = overrides[url.path] { return data }
        let file = root.appendingPathComponent(url.path.dropFirst().description)
        guard let data = try? Data(contentsOf: file) else {
            throw .providerUnreachable(reason: "no fixture for \(name)")
        }
        return data
    }

    func get(_ url: URL, headers _: [String: String], byteLimit _: Int64?)
        async throws(UpdateFailure) -> HTTPResponse
    {
        recorded.requests.append(url)
        if let status = statuses[url.path], status != 200 {
            return HTTPResponse(
                status: status, body: Data(), etag: nil, lastModified: nil,
                finalURL: url, retryAfter: nil)
        }
        let data = try body(for: url)
        return HTTPResponse(
            status: 200, body: data, etag: nil, lastModified: nil,
            finalURL: url, retryAfter: nil)
    }

    func download(
        _ url: URL, headers _: [String: String], into file: URL,
        byteLimit: Int64?
    ) async throws(UpdateFailure) -> DownloadResponse {
        recorded.requests.append(url)
        if let status = statuses[url.path], status != 200 {
            return DownloadResponse(
                status: status, bytesWritten: 0, sha256: nil, limitHit: false,
                finalURL: url, retryAfter: nil)
        }
        var data = try body(for: url)
        var limitHit = false
        if let limit = byteLimit, Int64(data.count) > limit {
            limitHit = true
            data = data.prefix(Int(limit))
        }
        do {
            try data.write(to: file)
        } catch {
            throw .downloadFailed(reason: "\(error)")
        }
        return DownloadResponse(
            status: 200, bytesWritten: Int64(data.count),
            sha256: SHA256Digest(data: data), limitHit: limitHit,
            finalURL: url, retryAfter: nil)
    }
}

private struct MemoryCache: ProviderCache {
    let root: URL
    func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct NoCredentials: ProviderCredentials {
    func token(for _: String) -> String? { nil }
    func setToken(_: String?, for _: String) throws {}
}

/// The test repository's signing-certificate fingerprint (committed by
/// scripts/dev/make-fdroid-repo.py).
private let testFingerprint =
    "867322208466d85ddf20f8bd8a946a7f39fc84754cf801ff92ecdd18457f695a"
/// test-fixture-a's signer digest; HelloUpdate V1/V2 carry it.
private let signerA =
    "a2f3893391ae70e6faee50a05c0d0c4b94505781f7af0d547c1625399e05f8b4"
private let pkgID = "io.apkrun.fixture.helloupdate"

private func fixtureRepo() throws -> (repo: String, dir: URL) {
    let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("../../../../Tests/Fixtures/update-repos/fdroid/repo")
        .standardizedFileURL
    return ("http://127.0.0.1:9/fdroid/repo", dir)
}

private func makeRef() throws -> UpdateProviderRef {
    let (repo, _) = try fixtureRepo()
    return try FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)")
}

private func makePackage(
    signer: String = signerA, sdk: Int = 37, abis: [String] = ["arm64-v8a"]
) throws -> InstalledPackage {
    InstalledPackage(
        id: try #require(PackageID(rawValue: pkgID)),
        versionCode: 1,
        signerDigests: [try #require(SHA256Digest(rawValue: "sha256:\(signer)"))],
        lineage: [],
        guest: GuestFacts(sdk: sdk, abis: abis),
        lastCursor: nil)
}

private func makeContext(
    http: FixtureHTTP, cache: URL,
    note: IncompatibleNoteRecorder = IncompatibleNoteRecorder()
) -> ProviderContext {
    ProviderContext(
        http: http, cache: MemoryCache(root: cache),
        credentials: NoCredentials(),
        incompatibleNote: { note.record($0) })
}

final class IncompatibleNoteRecorder: @unchecked Sendable {
    private(set) var reasons: [NoCompatibleArtifactReason] = []
    func record(_ reason: NoCompatibleArtifactReason) { reasons.append(reason) }
}

// MARK: - entry.jar verification (§4.5)

@Test func entryJarVerifiesWithTheRightFingerprint() throws {
    let (_, dir) = try fixtureRepo()
    let data = try FDroidIndexVerifier.entryJSON(
        in: dir.appendingPathComponent("entry.jar"),
        fingerprint: #require(SHA256Digest(hex: testFingerprint)))
    let entry = try JSONDecoder().decode(FDroidEntry.self, from: data)
    #expect(entry.index.name == "index-v2.json")
    #expect(!entry.diffs.isEmpty)
}

@Test func entryJarRefusesAWrongFingerprint() throws {
    let (_, dir) = try fixtureRepo()
    #expect(throws: UpdateFailure.self) {
        try FDroidIndexVerifier.entryJSON(
            in: dir.appendingPathComponent("entry.jar"),
            fingerprint: #require(SHA256Digest(hex: String(repeating: "a", count: 64))))
    }
}

@Test func entryJarRefusesAnUnsignedJar() throws {
    let (_, dir) = try fixtureRepo()
    #expect(throws: UpdateFailure.self) {
        try FDroidIndexVerifier.entryJSON(
            in: dir.appendingPathComponent("entry-unsigned.jar"),
            fingerprint: #require(SHA256Digest(hex: testFingerprint)))
    }
}

@Test func entryJarRefusesATamperedPayload() throws {
    let (_, dir) = try fixtureRepo()
    #expect(throws: UpdateFailure.self) {
        try FDroidIndexVerifier.entryJSON(
            in: dir.appendingPathComponent("entry-tampered.jar"),
            fingerprint: #require(SHA256Digest(hex: testFingerprint)))
    }
}

// MARK: - spec grammar

@Test func specBareFdroidPinsTheMainRepository() throws {
    let ref = try FDroidProvider.providerRef(for: "")
    guard case .fdroid(let repo, let fingerprint) = ref.configuration else {
        Issue.record("expected .fdroid configuration")
        return
    }
    #expect(repo == FDroidProvider.mainRepository)
    #expect(fingerprint == FDroidProvider.mainFingerprint)
    #expect(ref.type == .fdroid)
    #expect(try ProviderRegistry.parse("fdroid", developerModeEnabled: false) == ref)
    #expect(
        try UpdatePolicyRules.providerRef(for: ProviderSpec(spec: "fdroid")) == ref)
}

@Test func specParsesACustomRepository() throws {
    let fp = String(repeating: "b", count: 64)
    let ref = try FDroidProvider.providerRef(for: "https://fdroid.example.org/repo#\(fp)")
    guard case .fdroid(let repo, let fingerprint) = ref.configuration else {
        Issue.record("expected .fdroid configuration")
        return
    }
    #expect(repo == "https://fdroid.example.org/repo")
    #expect(fingerprint == fp)
}

@Test func specRejectsPlainHTTPAndBadForms() throws {
    let fp = String(repeating: "b", count: 64)
    #expect(throws: UpdateFailure.self) {
        try FDroidProvider.providerRef(for: "http://fdroid.example.org/repo#\(fp)")
    }
    #expect(throws: UpdateFailure.self) {
        try FDroidProvider.providerRef(for: "https://fdroid.example.org/repo")
    }
    #expect(throws: UpdateFailure.self) {
        try FDroidProvider.providerRef(for: "https://u:p@fdroid.example.org/repo#\(fp)")
    }
    #expect(throws: UpdateFailure.self) {
        try FDroidProvider.providerRef(for: "https://fdroid.example.org/repo#zz")
    }
}

// MARK: - check and selection (§4.5)

private func serveRepo(
    cache: URL, overrides: [String: Data] = [:]
) async throws -> (UpdateCandidate?, FixtureHTTP, IncompatibleNoteRecorder) {
    let (repo, dir) = try fixtureRepo()
    let http = FixtureHTTP(root: dir.deletingLastPathComponent().deletingLastPathComponent(), overrides: overrides)
    // The fixture URLs resolve <repo>/<file>; root serves update-repos/fdroid.
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)"))
    let note = IncompatibleNoteRecorder()
    let candidate = try await provider.check(
        makePackage(), context: makeContext(http: http, cache: cache, note: note))
    return (candidate, http, note)
}

@Test func checkFindsTheSignedV2Candidate() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let (found, http, note) = try await serveRepo(cache: cache)
    let candidate = try #require(found)
    #expect(candidate.declaredVersionCode == 2)
    #expect(candidate.artifacts.count == 1)
    #expect(candidate.artifacts[0].sha256 != nil)
    #expect(note.reasons.isEmpty)
    #expect(http.recorded.requests.count >= 2)  // entry.jar + index
}

@Test func checkReportsSignerDiffersWithoutACandidate() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let (repo, dir) = try fixtureRepo()
    let http = FixtureHTTP(root: dir.deletingLastPathComponent().deletingLastPathComponent())
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)"))
    let note = IncompatibleNoteRecorder()
    // A signer the index never carries: versions exist, none matches.
    let package = InstalledPackage(
        id: try #require(PackageID(rawValue: pkgID)),
        versionCode: 2,
        signerDigests: [
            try #require(SHA256Digest(rawValue: "sha256:\(String(repeating: "c", count: 64))"))
        ],
        lineage: [],
        guest: GuestFacts(sdk: 37, abis: ["arm64-v8a"]),
        lastCursor: nil)
    let candidate = try await provider.check(
        package, context: makeContext(http: http, cache: cache, note: note))
    #expect(candidate == nil)
    #expect(note.reasons == [.signerDiffers])
}

@Test func checkSkipsWhenNothingIsNewer() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let (repo, dir) = try fixtureRepo()
    let http = FixtureHTTP(root: dir.deletingLastPathComponent().deletingLastPathComponent())
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)"))
    let note = IncompatibleNoteRecorder()
    let package = InstalledPackage(
        id: try #require(PackageID(rawValue: pkgID)),
        versionCode: 10,
        signerDigests: [try #require(SHA256Digest(rawValue: "sha256:\(signerA)"))],
        lineage: [],
        guest: GuestFacts(sdk: 37, abis: ["arm64-v8a"]),
        lastCursor: nil)
    let candidate = try await provider.check(
        package, context: makeContext(http: http, cache: cache, note: note))
    #expect(candidate == nil)
    #expect(note.reasons.isEmpty)
}

@Test func checkRefusesABadEntrySignature() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let (repo, dir) = try fixtureRepo()
    let http = FixtureHTTP(root: dir.deletingLastPathComponent().deletingLastPathComponent())
    // Wrong fingerprint → providerSignatureInvalid before any index work.
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(
            for: "\(repo)#\(String(repeating: "d", count: 64))"))
    let note = IncompatibleNoteRecorder()
    do {
        _ = try await provider.check(
            makePackage(), context: makeContext(http: http, cache: cache, note: note))
        Issue.record("expected providerSignatureInvalid")
    } catch let failure as UpdateFailure {
        guard case .providerSignatureInvalid = failure else {
            Issue.record("expected providerSignatureInvalid, got \(failure)")
            return
        }
    }
}

@Test func checkRefusesAnIndexHashMismatch() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let (repo, dir) = try fixtureRepo()
    // Serve a corrupted index body.
    let http = FixtureHTTP(
        root: dir.deletingLastPathComponent().deletingLastPathComponent(),
        overrides: ["/fdroid/repo/index-v2.json": Data("{\"packages\":{}}".utf8)])
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)"))
    do {
        _ = try await provider.check(
            makePackage(), context: makeContext(http: http, cache: cache))
        Issue.record("expected providerMetadataInvalid")
    } catch let failure as UpdateFailure {
        guard case .providerMetadataInvalid = failure else {
            Issue.record("expected providerMetadataInvalid, got \(failure)")
            return
        }
    }
}

// MARK: - diff merge

@Test func diffMergesTheOldIndexToTheCurrentOne() throws {
    let (_, dir) = try fixtureRepo()
    let oldData = try Data(contentsOf: dir.appendingPathComponent("index-v2-old.json"))
    let newData = try Data(contentsOf: dir.appendingPathComponent("index-v2.json"))
    let diffData = try Data(
        contentsOf: dir.appendingPathComponent("diff/1700000000000.json"))
    let merged = try FDroidIndexReader().merged(index: oldData, diff: diffData)
    let mergedObject = try #require(
        try JSONSerialization.jsonObject(with: merged) as? [String: Any])
    let newObject = try #require(
        try JSONSerialization.jsonObject(with: newData) as? [String: Any])
    #expect(mergedObject as NSDictionary == newObject as NSDictionary)
}

@Test func checkSeedsCacheFromOldIndexThenAppliesTheDiff() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let (repo, dir) = try fixtureRepo()
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)"))
    // Seed the cache with the OLD index at the OLD timestamp.
    let cacheDir = try MemoryCache(root: cache).directory(
        forKey: provider.cacheKey)
    try Data(contentsOf: dir.appendingPathComponent("index-v2-old.json"))
        .write(to: cacheDir.appendingPathComponent("index.json"))
    try Data(
        "{\"timestamp\":1700000000000,\"sha256\":\"x\"}".utf8
    ).write(to: cacheDir.appendingPathComponent("index.meta.json"))

    let http = FixtureHTTP(root: dir.deletingLastPathComponent().deletingLastPathComponent())
    let candidate = try await provider.check(
        makePackage(), context: makeContext(http: http, cache: cache))
    #expect(candidate?.declaredVersionCode == 2)
    // entry.jar + the diff — not the full index.
    let paths = http.recorded.requests.map(\.lastPathComponent)
    #expect(paths.contains("entry.jar"))
    #expect(paths.contains("1700000000000.json"))
    #expect(!paths.contains("index-v2.json"))
}

@Test func checkReusesTheCachedIndexWithoutFetching() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let (repo, dir) = try fixtureRepo()
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)"))
    let cacheDir = try MemoryCache(root: cache).directory(
        forKey: provider.cacheKey)
    let indexData = try Data(
        contentsOf: dir.appendingPathComponent("index-v2.json"))
    try indexData.write(to: cacheDir.appendingPathComponent("index.json"))
    try Data(
        "{\"timestamp\":1700000100000,\"sha256\":\"\(SHA256Digest(data: indexData).hexValue)\"}"
            .utf8
    ).write(to: cacheDir.appendingPathComponent("index.meta.json"))

    let http = FixtureHTTP(root: dir.deletingLastPathComponent().deletingLastPathComponent())
    let candidate = try await provider.check(
        makePackage(), context: makeContext(http: http, cache: cache))
    #expect(candidate?.declaredVersionCode == 2)
    let paths = http.recorded.requests.map(\.lastPathComponent)
    #expect(paths == ["entry.jar"])
}

// MARK: - download

@Test func downloadFetchesTheChosenAPK() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let (repo, dir) = try fixtureRepo()
    let http = FixtureHTTP(root: dir.deletingLastPathComponent().deletingLastPathComponent())
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)"))
    guard
        let candidate = try await provider.check(
            makePackage(), context: makeContext(http: http, cache: cache))
    else {
        Issue.record("no candidate")
        return
    }
    let artifact = try await provider.download(
        candidate, to: DownloadDestination(ticket: UUID(), directory: destination),
        context: makeContext(http: http, cache: cache)
    ) { _ in }
    guard case .apk(let file) = artifact else {
        Issue.record("expected an .apk artifact")
        return
    }
    let expected = try Data(
        contentsOf: dir.appendingPathComponent("io.apkrun.fixture.helloupdate_2.apk"))
    #expect(try Data(contentsOf: file) == expected)
}

@Test func downloadRetriesAHashMismatchThenFails() async throws {
    let cache = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-test-\(UUID().uuidString)")
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("fdroid-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let (repo, dir) = try fixtureRepo()
    var overrides: [String: Data] = [:]
    overrides["/fdroid/repo/io.apkrun.fixture.helloupdate_2.apk"] = Data("bad".utf8)
    let http = FixtureHTTP(root: dir.deletingLastPathComponent().deletingLastPathComponent(), overrides: overrides)
    let provider = try FDroidProvider(
        ref: FDroidProvider.providerRef(for: "\(repo)#\(testFingerprint)"))
    guard
        let candidate = try await provider.check(
            makePackage(), context: makeContext(http: http, cache: cache))
    else {
        Issue.record("no candidate")
        return
    }
    await #expect(throws: UpdateFailure.self) {
        try await provider.download(
            candidate, to: DownloadDestination(ticket: UUID(), directory: destination),
            context: makeContext(http: http, cache: cache)
        ) { _ in }
    }
}

// MARK: - reader limits

@Test func readerKeepsOnlyRequestedPackagesWithinTheByteBudget() throws {
    let (_, dir) = try fixtureRepo()
    let data = try Data(contentsOf: dir.appendingPathComponent("index-v2.json"))
    let keep = try #require(PackageID(rawValue: pkgID))
    let packages = try FDroidIndexReader().packages(in: data, keep: [keep])
    #expect(packages.count == 1)
    #expect(packages[keep]?.versions.count == 3)
    let other = try FDroidIndexReader().packages(
        in: data, keep: [try #require(PackageID(rawValue: "org.other.app"))])
    #expect(other.isEmpty)
}
