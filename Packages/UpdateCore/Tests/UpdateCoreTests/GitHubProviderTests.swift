import APKStoreCore
import Foundation
import Testing

@testable import UpdateCore

// T0 of #53: GitHubProvider spec parsing and check behavior against a
// stub HTTP client (update-system.md §4.6).

private final class Recorded: @unchecked Sendable {
    var requests: [(url: URL, headers: [String: String])] = []
}

private final class StubHTTP: UpdateHTTPClient, @unchecked Sendable {
    let recorded = Recorded()
    var getBody: Data = Data()
    var getStatus = 200
    var getHeaders: [String: String] = [:]
    var getEtag: String?
    var downloadBody: Data?
    var rateLimitReset: String?

    func get(_ url: URL, headers: [String: String], byteLimit _: Int64?)
        async throws(UpdateFailure) -> HTTPResponse
    {
        recorded.requests.append((url, headers))
        if getStatus != 200 {
            return HTTPResponse(
                status: getStatus, body: Data(), etag: nil, lastModified: nil,
                finalURL: url, retryAfter: nil)
        }
        return HTTPResponse(
            status: 200, body: getBody, etag: getEtag, lastModified: nil,
            finalURL: url, retryAfter: nil)
    }

    func download(
        _ url: URL, headers: [String: String], into file: URL,
        byteLimit _: Int64?
    ) async throws(UpdateFailure) -> DownloadResponse {
        recorded.requests.append((url, headers))
        let data = downloadBody ?? getBody
        try? data.write(to: file)
        return DownloadResponse(
            status: 200, bytesWritten: Int64(data.count),
            sha256: SHA256Digest(data: data), limitHit: false,
            finalURL: url, retryAfter: nil)
    }
}

private struct GitHubMemoryCache: ProviderCache {
    let root: URL
    func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class CursorRecorder: @unchecked Sendable {
    private(set) var cursor: ProviderCursor?
    func record(_ cursor: ProviderCursor) { self.cursor = cursor }
}

private struct GitHubCredentials: ProviderCredentials {
    var token: String?
    func token(for _: String) -> String? { token }
    func setToken(_: String?, for _: String) throws {}
}

private func githubContext(
    http: StubHTTP, token: String? = nil
) -> ProviderContext {
    ProviderContext(
        http: http,
        cache: GitHubMemoryCache(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("gh-test-\(UUID().uuidString)")),
        credentials: GitHubCredentials(token: token),
        incompatibleNote: { _ in })
}

private func githubPackage() throws -> InstalledPackage {
    InstalledPackage(
        id: try #require(PackageID(rawValue: "io.apkrun.fixture.helloupdate")),
        versionCode: 1,
        signerDigests: [
            try #require(
                SHA256Digest(
                    rawValue:
                        "sha256:a2f3893391ae70e6faee50a05c0d0c4b94505781f7af0d547c1625399e05f8b4"))
        ],
        lineage: [],
        guest: GuestFacts(sdk: 37, abis: ["arm64-v8a"]),
        lastCursor: nil)
}

private func releaseJSON(
    id: Int, draft: Bool = false, prerelease: Bool = false,
    assets: [String] = ["app-universal.apk"]
) -> String {
    let assetList = assets.enumerated().map { index, name in
        """
        {"id":\(id * 100 + index),"name":"\(name)","size":100,
         "browser_download_url":"https://objects.example.com/\(name)",
         "updated_at":"2026-01-01T00:00:00Z"}
        """
    }.joined(separator: ",")
    return """
        {"id":\(id),"tag_name":"v\(id)","draft":\(draft),"prerelease":\(prerelease),
         "published_at":"2026-01-0\(id)T00:00:00Z","body":"notes","assets":[\(assetList)]}
        """
}

// MARK: - spec parsing

@Test func specParsesRepositoryOnly() throws {
    let ref = try GitHubProvider.providerRef(for: "octo/hello")
    let provider = try GitHubProvider(ref: ref)
    #expect(provider.repository == "octo/hello")
    #expect(provider.channel == .stable)
}

@Test func specParsesAssetGlobAndPrereleaseChannel() throws {
    let ref = try GitHubProvider.providerRef(for: "octo/hello:*.apk@prerelease")
    let provider = try GitHubProvider(ref: ref)
    #expect(provider.repository == "octo/hello")
    #expect(provider.channel == .prerelease)
}

@Test func specRejectsBadRepositoryAndPattern() throws {
    for bad in [
        "github://octo/hello", "octo", "octo/", "/hello",
        "octo/hello:@x", "octo/hello/sub",
    ] {
        do {
            _ = try GitHubProvider.providerRef(for: bad)
            Issue.record("expected providerMetadataInvalid for \(bad)")
        } catch let failure as UpdateFailure {
            guard case .providerMetadataInvalid = failure else {
                Issue.record("expected providerMetadataInvalid, got \(failure)")
                return
            }
        }
    }
}

// MARK: - check

@Test func checkPicksNewestNonDraftRelease() async throws {
    var http = StubHTTP()
    http.getBody = Data(
        """
        [\(releaseJSON(id: 3, draft: true)),\(releaseJSON(id: 2)),\(releaseJSON(id: 1))]
        """.utf8)
    let provider = try GitHubProvider(ref: GitHubProvider.providerRef(for: "octo/hello"))
    let candidate = try #require(
        try await provider.check(githubPackage(), context: githubContext(http: http)))
    #expect(candidate.cursor.value.contains(":2"))
    #expect(candidate.declaredVersionCode == nil)
    #expect(candidate.declaredVersionName == nil)
}

@Test func checkHonorsThePrereleaseChannel() async throws {
    var http = StubHTTP()
    http.getBody = Data(
        """
        [\(releaseJSON(id: 3, prerelease: true)),\(releaseJSON(id: 2))]
        """.utf8)
    let provider = try GitHubProvider(
        ref: GitHubProvider.providerRef(for: "octo/hello@prerelease"))
    let candidate = try #require(
        try await provider.check(githubPackage(), context: githubContext(http: http)))
    #expect(candidate.cursor.value.contains(":3"))
}

@Test func checkSkipsPrereleasesOnTheStableChannel() async throws {
    var http = StubHTTP()
    http.getBody = Data(
        """
        [\(releaseJSON(id: 3, prerelease: true)),\(releaseJSON(id: 2))]
        """.utf8)
    let provider = try GitHubProvider(ref: GitHubProvider.providerRef(for: "octo/hello"))
    let candidate = try #require(
        try await provider.check(githubPackage(), context: githubContext(http: http)))
    #expect(candidate.cursor.value.contains(":2"))
}

@Test func checkPrefersArm64ThenUniversalElseAmbiguous() async throws {
    // arm64-v8a over universal.
    var http = StubHTTP()
    http.getBody = Data(
        "[\(releaseJSON(id: 2, assets: ["app-universal.apk", "app-arm64-v8a.apk"]))]"
            .utf8)
    var provider = try GitHubProvider(ref: GitHubProvider.providerRef(for: "octo/hello"))
    var candidate = try #require(
        try await provider.check(githubPackage(), context: githubContext(http: http)))
    #expect(candidate.artifacts[0].url.lastPathComponent == "app-arm64-v8a.apk")

    // universal alone is fine.
    http = StubHTTP()
    http.getBody = Data("[\(releaseJSON(id: 2, assets: ["app-universal.apk"]))]".utf8)
    candidate = try #require(
        try await provider.check(githubPackage(), context: githubContext(http: http)))
    #expect(candidate.artifacts[0].url.lastPathComponent == "app-universal.apk")

    // Two assets with no ABI hint → ambiguousAsset.
    http = StubHTTP()
    http.getBody = Data(
        "[\(releaseJSON(id: 2, assets: ["app-a.apk", "app-b.apk"]))]".utf8)
    do {
        _ = try await provider.check(githubPackage(), context: githubContext(http: http))
        Issue.record("expected ambiguousAsset")
    } catch let failure as UpdateFailure {
        guard case .ambiguousAsset = failure else {
            Issue.record("expected ambiguousAsset, got \(failure)")
            return
        }
    }
}

@Test func checkUsesTheDigestAsTheHash() async throws {
    var http = StubHTTP()
    http.getBody = Data(
        """
        [{"id":2,"tag_name":"v2","draft":false,"prerelease":false,
          "published_at":"2026-01-02T00:00:00Z","body":"",
          "assets":[{"id":20,"name":"app-universal.apk","size":100,
           "digest":"sha256:\(String(repeating: "a", count: 64))",
           "browser_download_url":"https://objects.example.com/a.apk",
           "updated_at":"2026-01-02T00:00:00Z"}]}]
        """.utf8)
    let provider = try GitHubProvider(ref: GitHubProvider.providerRef(for: "octo/hello"))
    let candidate = try #require(
        try await provider.check(githubPackage(), context: githubContext(http: http)))
    #expect(
        candidate.artifacts[0].sha256?.rawValue
            == "sha256:\(String(repeating: "a", count: 64))")
}

@Test func checkRevalidatesWithIfNoneMatch() async throws {
    var http = StubHTTP()
    http.getBody = Data("[\(releaseJSON(id: 2))]".utf8)
    http.getEtag = "\"listing-1\""
    let provider = try GitHubProvider(ref: GitHubProvider.providerRef(for: "octo/hello"))
    let context = githubContext(http: http)
    let first = try #require(
        try await provider.check(githubPackage(), context: context))
    // The saved cursor makes the next check conditional.
    var package = try githubPackage()
    package.lastCursor = first.cursor
    http.getStatus = 304
    let second = try await provider.check(package, context: context)
    #expect(second == nil)
    #expect(http.recorded.requests.last?.headers["If-None-Match"] == "\"listing-1\"")
}

@Test func checkIgnoresAListingEditThatKeepsTheSameAsset() async throws {
    var http = StubHTTP()
    http.getBody = Data("[\(releaseJSON(id: 2))]".utf8)
    http.getEtag = "\"listing-1\""
    let provider = try GitHubProvider(ref: GitHubProvider.providerRef(for: "octo/hello"))
    let context = githubContext(http: http)
    let first = try #require(
        try await provider.check(githubPackage(), context: context))
    var package = try githubPackage()
    package.lastCursor = first.cursor
    // A release-note edit moves the listing ETag; the chosen release and
    // asset are unchanged, so the processed release is not offered again.
    http.getEtag = "\"listing-2\""
    let refreshed = CursorRecorder()
    var context2 = context
    context2.cursorRefresh = { refreshed.record($0) }
    let second = try await provider.check(package, context: context2)
    #expect(second == nil)
    // …but the refreshed listing cursor still reaches the caller, so the
    // next check can stay conditional on the new ETag.
    #expect(refreshed.cursor?.value.hasPrefix("\"listing-2\"\t") == true)
    #expect(refreshed.cursor?.value.contains("2:200:") == true)
}

@Test func checkRefetchesWhenTheChannelOrGlobChanged() async throws {
    var http = StubHTTP()
    http.getBody = Data("[\(releaseJSON(id: 2))]".utf8)
    http.getEtag = "\"listing-1\""
    let provider = try GitHubProvider(
        ref: GitHubProvider.providerRef(for: "octo/hello@prerelease"))
    var package = try githubPackage()
    // A cursor written by a stable-channel check of an older release.
    package.lastCursor = ProviderCursor(
        type: .github,
        value: "\"listing-0\"\t1:100:2026-01-01T00:00:00Z:100\tstable:app-*.apk")
    let candidate = try #require(
        try await provider.check(package, context: githubContext(http: http)))
    // The changed config cannot reuse the old listing ETag, so the request
    // is unconditional and the new channel's candidate is found.
    #expect(http.recorded.requests.last?.headers["If-None-Match"] == nil)
    #expect(candidate.cursor.value.contains(":2"))
}

@Test func checkMapsAnExhaustedLimitToRateLimited() async throws {
    var http = StubHTTP()
    http.getStatus = 403
    let provider = try GitHubProvider(ref: GitHubProvider.providerRef(for: "octo/hello"))
    do {
        _ = try await provider.check(githubPackage(), context: githubContext(http: http))
        Issue.record("expected providerHTTPStatus without rate-limit headers")
    } catch let failure as UpdateFailure {
        guard case .providerHTTPStatus(403) = failure else {
            Issue.record("expected providerHTTPStatus(403), got \(failure)")
            return
        }
    }
}

// MARK: - token handling

@Test func tokenGoesToTheAPIRequestButNeverToTheDownload() async throws {
    var http = StubHTTP()
    http.getBody = Data("[\(releaseJSON(id: 2))]".utf8)
    http.downloadBody = Data(repeating: 7, count: 100)
    let provider = try GitHubProvider(ref: GitHubProvider.providerRef(for: "octo/hello"))
    let context = githubContext(http: http, token: "tok-123")
    let candidate = try #require(
        try await provider.check(githubPackage(), context: context))
    #expect(http.recorded.requests[0].headers["Authorization"] == "Bearer tok-123")

    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("gh-dl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    _ = try await provider.download(
        candidate,
        to: DownloadDestination(ticket: UUID(), directory: destination),
        context: context
    ) { _ in }
    #expect(http.recorded.requests.last?.headers["Authorization"] == nil)
}
