import APKStoreCore
import CryptoKit
import Foundation
import RuntimeAPI
import Testing

@testable import UpdateCore

/// A scripted client: `get` serves manifest bodies from the fixture store,
/// `download` copies a payload to the destination.
private struct ScriptedHTTP: UpdateHTTPClient {
    /// Fixture body per manifest URL.
    var manifests: [String: HTTPResponse]
    /// Payload bytes per artifact URL.
    var payloads: [String: Data] = [:]
    /// The If-None-Match headers seen.
    let seen = Seen()

    final class Seen: @unchecked Sendable {
        var ifNoneMatch: [String] = []
    }

    func get(
        _ url: URL, headers: [String: String], byteLimit: Int64?
    ) async throws(UpdateFailure) -> HTTPResponse {
        if let etag = headers["If-None-Match"] {
            seen.ifNoneMatch.append(etag)
        }
        guard let response = manifests[url.absoluteString] else {
            throw UpdateFailure.providerUnreachable(reason: "unscripted URL \(url)")
        }
        return response
    }

    func download(
        _ url: URL,
        headers _: [String: String],
        into file: URL,
        byteLimit: Int64?
    ) async throws(UpdateFailure) -> DownloadResponse {
        guard var data = payloads[url.absoluteString] else {
            throw UpdateFailure.providerUnreachable(reason: "unscripted URL \(url)")
        }
        var limitHit = false
        if let limit = byteLimit, data.count > limit {
            limitHit = true
            data = data.prefix(Int(limit))
        }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: file)
        } catch {
            throw UpdateFailure.downloadFailed(reason: error.localizedDescription)
        }
        return DownloadResponse(
            status: 200,
            bytesWritten: Int64(data.count),
            sha256: SHA256Digest(data: data),
            limitHit: limitHit,
            finalURL: url,
            retryAfter: nil)
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

private func makePackage(
    _ id: String = "com.example.app",
    versionCode: VersionCode = 1,
    sdk: Int = 37,
    cursor: ProviderCursor? = nil
) throws -> InstalledPackage {
    InstalledPackage(
        id: try #require(PackageID(rawValue: id)),
        versionCode: versionCode,
        signerDigests: [],
        lineage: [],
        guest: GuestFacts(sdk: sdk),
        lastCursor: cursor)
}

private func makeProvider(manifestURL: String = "https://updates.example.com/app.json") throws
    -> DirectProvider
{
    try DirectProvider(
        ref: UpdateProviderRef(
            type: .direct,
            configuration: .direct(url: manifestURL)))
}

private func fixture(_ name: String) throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = root.appendingPathComponent(
        "Tests/Fixtures/update-repos/direct/\(name).json")
    return try Data(contentsOf: url)
}

private func context(
    _ http: ScriptedHTTP, root: URL, userInitiated: Bool = false
) -> ProviderContext {
    ProviderContext(
        http: http,
        cache: MemoryCache(root: root),
        credentials: NoCredentials(),
        userInitiated: userInitiated)
}

private func respond(_ name: String, etag: String? = nil, status: Int = 200) throws
    -> HTTPResponse
{
    HTTPResponse(
        status: status,
        body: try fixture("valid/\(name)"),
        etag: etag,
        lastModified: nil)
}

// MARK: - candidates

@Test func directProviderReturnsCandidateForNewerVersion() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("single-apk", etag: "\"v2\"")

    let provider = try makeProvider()
    let candidate = try await provider.check(
        makePackage(), context: context(http, root: root))

    let candidate2 = try #require(candidate)
    #expect(candidate2.declaredVersionCode == 2)
    #expect(candidate2.declaredVersionName == "1.1")
    #expect(candidate2.releaseNotes == "Bug fixes.")
    #expect(candidate2.cursor == ProviderCursor(type: .direct, value: "\(url)\t\"v2\""))
    #expect(candidate2.declaredSignerDigests?.count == 1)
    #expect(candidate2.artifacts.count == 1)
    #expect(candidate2.artifacts[0].kind == .apk)
    #expect(candidate2.artifacts[0].url.absoluteString == "https://files.example.com/app-2.apk")
    #expect(candidate2.artifacts[0].sha256?.hexValue.count == 64)
    #expect(candidate2.artifacts[0].size == 1024)
}

@Test func directProviderResolvesRelativeURLsAgainstManifest() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/apps/app.json"
    var http = ScriptedHTTP(manifests: [:])
    var response = try respond("split-set")
    response.finalURL = URL(string: "https://cdn.example.com/m/app.json")
    http.manifests[url] = response

    let provider = try makeProvider(manifestURL: url)
    let candidate = try await provider.check(
        makePackage(), context: context(http, root: root))

    let artifacts = try #require(candidate?.artifacts)
    #expect(artifacts.count == 3)
    // §5.3: relative references resolve against the *final* manifest URL.
    #expect(artifacts[0].url.absoluteString == "https://cdn.example.com/m/base.apk")
    #expect(artifacts[1].url.absoluteString == "https://cdn.example.com/m/splits/config.arm64_v8a.apk")
    #expect(artifacts[1].kind == .split("config.arm64_v8a"))
    #expect(artifacts[2].kind == .split("feature_hd"))
}

@Test func directProviderReturnsNilWhenNotNewer() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("not-newer")

    let provider = try makeProvider()
    let candidate = try await provider.check(
        makePackage(versionCode: 1), context: context(http, root: root))
    #expect(candidate == nil)
}

@Test func directProviderReturnsNilOn304AndSendsETag() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = HTTPResponse(status: 304, body: Data())

    let provider = try makeProvider()
    let cursor = ProviderCursor(type: .direct, value: "\(url)\t\"v1\"")
    let candidate = try await provider.check(
        makePackage(cursor: cursor), context: context(http, root: root))
    #expect(candidate == nil)
    #expect(http.seen.ifNoneMatch == ["\"v1\""])
}

@Test func directProviderDedupesOnSameCursor() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("single-apk", etag: "\"v2\"")

    let provider = try makeProvider()
    let candidate = try await provider.check(
        makePackage(cursor: ProviderCursor(type: .direct, value: "\(url)\t\"v2\"")),
        context: context(http, root: root))
    #expect(candidate == nil)
}

@Test func directProviderUserInitiatedCheckRefetchesAndIgnoresCursor() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("single-apk", etag: "\"v2\"")

    let provider = try makeProvider()
    let candidate = try await provider.check(
        makePackage(cursor: ProviderCursor(type: .direct, value: "\(url)\t\"v2\"")),
        context: context(http, root: root, userInitiated: true))
    #expect(candidate != nil)
    #expect(http.seen.ifNoneMatch.isEmpty)
}

@Test func directProviderCursorDoesNotLeakAcrossManifestURLs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldURL = "https://updates.example.com/app.json"
    let newURL = "https://updates.example.com/new-app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[newURL] = try respond("single-apk", etag: "\"v9\"")

    let provider = try makeProvider(manifestURL: newURL)
    let candidate = try await provider.check(
        makePackage(cursor: ProviderCursor(type: .direct, value: "\(oldURL)\t\"v1\"")),
        context: context(http, root: root))
    #expect(candidate != nil)
    #expect(http.seen.ifNoneMatch.isEmpty)
}

@Test func directProviderCursorFallsBackToBodyHash() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("single-apk")  // no ETag

    let provider = try makeProvider()
    let candidate = try await provider.check(
        makePackage(), context: context(http, root: root))
    let body = try fixture("valid/single-apk")
    let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    #expect(candidate?.cursor.value == "\(url)\tsha256:\(digest)")
}

// MARK: - status mapping

@Test func directProviderMapsRateLimitAndHTTPStatus() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    let provider = try makeProvider()
    let package = try makePackage()

    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = HTTPResponse(status: 429, body: Data(), retryAfter: 30)
    await #expect(throws: UpdateFailure.self) {
        _ = try await provider.check(package, context: context(http, root: root))
    }
    do {
        _ = try await provider.check(package, context: context(http, root: root))
        Issue.record("expected providerRateLimited")
    } catch let error as UpdateFailure {
        guard case .providerRateLimited(let retryAfter) = error else {
            Issue.record("expected providerRateLimited, got \(error)")
            return
        }
        #expect(retryAfter == 30)
    }

    http.manifests[url] = HTTPResponse(status: 500, body: Data())
    do {
        _ = try await provider.check(package, context: context(http, root: root))
        Issue.record("expected providerHTTPStatus")
    } catch let error as UpdateFailure {
        guard case .providerHTTPStatus(500) = error else {
            Issue.record("expected providerHTTPStatus, got \(error)")
            return
        }
    }
}

// MARK: - D rules

@Test func directProviderRejectsInvalidManifests() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    let provider = try makeProvider()
    let package = try makePackage()

    for file in [
        "schema-version", "package-mismatch", "bad-sha", "mixed-shapes",
        "http-artifact", "user-info-url", "duplicate-split", "split-no-name",
        "oversize-total", "not-json", "not-utf8",
    ] {
        var http = ScriptedHTTP(manifests: [:])
        http.manifests[url] = HTTPResponse(
            status: 200, body: try fixture("invalid/\(file)"))
        do {
            _ = try await provider.check(package, context: context(http, root: root))
            Issue.record("\(file): expected providerMetadataInvalid")
        } catch let error as UpdateFailure {
            guard case .providerMetadataInvalid = error else {
                Issue.record("\(file): expected providerMetadataInvalid, got \(error)")
                continue
            }
        }
    }
}

@Test func directProviderD2DetailIsExact() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = HTTPResponse(
        status: 200, body: try fixture("invalid/schema-version"))

    let provider = try makeProvider()
    do {
        _ = try await provider.check(
            makePackage(), context: context(http, root: root))
        Issue.record("expected failure")
    } catch let error as UpdateFailure {
        guard case .providerMetadataInvalid(let detail) = error else {
            Issue.record("expected providerMetadataInvalid, got \(error)")
            return
        }
        #expect(detail == "unsupported schemaVersion 2; update APKRun")
    }
}

@Test func directProviderRefusesTooNewMinSdk() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("min-sdk-too-high")

    let provider = try makeProvider()
    do {
        _ = try await provider.check(
            makePackage(sdk: 37), context: context(http, root: root))
        Issue.record("expected noCompatibleArtifact")
    } catch let error as UpdateFailure {
        guard case .noCompatibleArtifact(.sdkTooLow) = error else {
            Issue.record("expected noCompatibleArtifact(.sdkTooLow), got \(error)")
            return
        }
    }
}

/// Artifacts that share a URL basename are valid (base + split APKs often
/// do); they stage under index-prefixed names so neither overwrites the
/// other (UpdateCore storedFileName(index:in:)).
@Test func directProviderStagesCollidingBasenamesByIndex() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])

    let payload = Data(repeating: 0xCD, count: 512)
    let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    let manifest = String(data: try fixture("invalid/duplicate-file-name"), encoding: .utf8)!
        .replacingOccurrences(of: String(repeating: "a", count: 64), with: sha)
        .data(using: .utf8)!
    http.manifests[url] = HTTPResponse(status: 200, body: manifest)
    http.payloads["https://files.example.com/v2/app.apk"] = payload
    http.payloads["https://files.example.com/splits/app.apk"] = payload

    let provider = try makeProvider()
    let candidate = try #require(
        await provider.check(makePackage(), context: context(http, root: root)))
    let destination = DownloadDestination(
        ticket: UUID(), directory: root.appendingPathComponent("dl"))
    _ = try await provider.download(
        candidate, to: destination, context: context(http, root: root),
        progress: { _ in })

    let staged = try FileManager.default.contentsOfDirectory(
        atPath: destination.directory.path
    ).sorted()
    #expect(staged == ["0-app.apk", "1-app.apk"])
}

// MARK: - download

@Test func directProviderDownloadsAndVerifiesHashes() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("single-apk")
    let provider = try makeProvider()
    let candidate = try #require(
        await provider.check(makePackage(), context: context(http, root: root)))

    // The manifest declares sha256 = "aa…" so provide matching bytes.
    let payload = Data(repeating: 0xAB, count: 1024)
    let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    var manifest = try respond("single-apk")
    manifest.body = String(data: manifest.body, encoding: .utf8)!
        .replacingOccurrences(of: String(repeating: "a", count: 64), with: sha)
        .data(using: .utf8)!
    http.manifests[url] = manifest
    http.payloads["https://files.example.com/app-2.apk"] = payload

    let checked = try #require(
        await provider.check(makePackage(), context: context(http, root: root)))
    #expect(checked.cursor.value.hasPrefix("\(url)\tsha256:"))
    #expect(candidate.cursor.value.hasPrefix("\(url)\tsha256:"))

    final class Samples: @unchecked Sendable { var values: [DownloadProgress] = [] }
    let samples = Samples()
    let destination = DownloadDestination(
        ticket: UUID(), directory: root.appendingPathComponent("dl"))
    let artifact = try await provider.download(
        checked, to: destination, context: context(http, root: root),
        progress: { samples.values.append($0) })
    guard case .apk(let file) = artifact else {
        Issue.record("expected .apk, got \(artifact)")
        return
    }
    #expect(try Data(contentsOf: file) == payload)
    #expect(samples.values.last?.bytesWritten == 1024)
}

@Test func directProviderRetriesHashMismatchOnce() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("single-apk")
    http.payloads["https://files.example.com/app-2.apk"] = Data(repeating: 0x00, count: 1024)

    let provider = try makeProvider()
    let candidate = try #require(
        await provider.check(makePackage(), context: context(http, root: root)))
    let destination = DownloadDestination(
        ticket: UUID(), directory: root.appendingPathComponent("dl"))
    do {
        _ = try await provider.download(
            candidate, to: destination, context: context(http, root: root),
            progress: { _ in })
        Issue.record("expected hashMismatch")
    } catch let error as UpdateFailure {
        guard case .hashMismatch = error else {
            Issue.record("expected hashMismatch, got \(error)")
            return
        }
    }
}

@Test func directProviderRejectsOversizedDownload() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-direct-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = "https://updates.example.com/app.json"
    var http = ScriptedHTTP(manifests: [:])
    http.manifests[url] = try respond("container")
    let payload = Data(repeating: 0xCD, count: 1_048_577)  // one byte over
    let sha = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    var manifest = try respond("container")
    manifest.body = String(data: manifest.body, encoding: .utf8)!
        .replacingOccurrences(of: String(repeating: "a", count: 64), with: sha)
        .data(using: .utf8)!
    http.manifests[url] = manifest
    http.payloads["https://files.example.com/app-4.apks"] = payload

    let provider = try makeProvider()
    let candidate = try #require(
        await provider.check(makePackage(), context: context(http, root: root)))
    let destination = DownloadDestination(
        ticket: UUID(), directory: root.appendingPathComponent("dl"))
    // One byte over the declared size → mismatch, retried, then hashMismatch.
    do {
        _ = try await provider.download(
            candidate, to: destination, context: context(http, root: root),
            progress: { _ in })
        Issue.record("expected hashMismatch")
    } catch let error as UpdateFailure {
        guard case .hashMismatch = error else {
            Issue.record("expected hashMismatch, got \(error)")
            return
        }
    }
}

// MARK: - registry and spec

@Test func providerRegistryBuildsDirectProvider() throws {
    let ref = try ProviderRegistry.parse(
        "direct:https://updates.example.com/app.json",
        developerModeEnabled: false)
    let provider = try ProviderRegistry.provider(for: ref, developerModeEnabled: false)
    #expect(provider is DirectProvider)
}

@Test func providerRegistryRejectsBadDirectSpecs() throws {
    for spec in [
        "direct:http://files.example.com/app.json",
        "direct:https://user@files.example.com/app.json",
        "direct:not-a-url",
        "direct:https://files.example.com/\(String(repeating: "x", count: 2048))",
    ] {
        #expect(throws: UpdateFailure.self) {
            _ = try ProviderRegistry.parse(spec, developerModeEnabled: true)
        }
    }
}

@Test func updatePolicyRulesBuildsDirectRef() throws {
    let ref = try UpdatePolicyRules.providerRef(
        for: ProviderSpec(spec: "direct:https://updates.example.com/app.json"))
    #expect(ref.type == .direct)
    guard case .direct(let url) = ref.configuration else {
        Issue.record("expected .direct, got \(ref.configuration)")
        return
    }
    #expect(url == "https://updates.example.com/app.json")
}

/// §12: every key any fixture uses is a property the published schema
/// declares, at the top level and inside `artifacts`.
@Test func fixturesAgreeWithPublishedSchema() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let schemaData = try Data(
        contentsOf: root.appendingPathComponent(
            "docs/03-reference/schemas/direct-provider-manifest.schema.json"))
    let schema = try #require(
        JSONSerialization.jsonObject(with: schemaData) as? [String: Any])
    let topProperties = Set(
        (schema["properties"] as? [String: Any] ?? [:]).keys)
    let defs = schema["$defs"] as? [String: Any] ?? [:]
    let artifact = defs["artifact"] as? [String: Any] ?? [:]
    let artifactProperties = Set(
        (artifact["properties"] as? [String: Any] ?? [:]).keys)
    let manager = FileManager.default
    let fixtureRoot = root.appendingPathComponent(
        "Tests/Fixtures/update-repos/direct")
    for group in ["valid", "invalid"] {
        let directory = fixtureRoot.appendingPathComponent(group)
        for name in try manager.contentsOfDirectory(atPath: directory.path)
        where name.hasSuffix(".json") {
            let data = try Data(
                contentsOf: directory.appendingPathComponent(name))
            guard
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else { continue }
            #expect(
                Set(object.keys).isSubset(of: topProperties),
                "\(group)/\(name): undeclared top-level keys")
            for item in object["artifacts"] as? [[String: Any]] ?? [] {
                #expect(
                    Set(item.keys).isSubset(of: artifactProperties),
                    "\(group)/\(name): undeclared artifact keys")
            }
        }
    }
}
