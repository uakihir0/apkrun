import APKStoreCore
import Foundation
import Testing

@testable import UpdateCore

// T1 of #53: GitHubProvider over real loopback HTTP against
// scripts/dev/update-server.py serving the committed fixture releases
// (update-system.md §4.6).

private let githubPackageID = "io.apkrun.fixture.helloupdate"
private let githubSigner =
    "a2f3893391ae70e6faee50a05c0d0c4b94505781f7af0d547c1625399e05f8b4"

private struct GitHubMemoryCache: ProviderCache {
    let root: URL
    func directory(forKey key: String) throws -> URL {
        let directory = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct GitHubCredentials: ProviderCredentials {
    var token: String?
    func token(for _: String) -> String? { token }
    func setToken(_: String?, for _: String) throws {}
}

private func githubContext(root: URL, token: String? = nil) -> ProviderContext {
    ProviderContext(
        http: URLSessionUpdateHTTPClient(),
        cache: GitHubMemoryCache(root: root),
        credentials: GitHubCredentials(token: token),
        incompatibleNote: { _ in })
}

private func githubProvider(
    _ server: UpdateServer, spec: String = "octo/hello"
) throws -> GitHubProvider {
    try GitHubProvider(
        ref: GitHubProvider.providerRef(for: spec),
        apiBase: server.baseURL.appendingPathComponent("github"))
}

private func installedGitHubPackage(
    versionCode: VersionCode = 1, lastCursor: ProviderCursor? = nil
) throws -> InstalledPackage {
    InstalledPackage(
        id: try #require(PackageID(rawValue: githubPackageID)),
        versionCode: versionCode,
        signerDigests: [
            try #require(SHA256Digest(rawValue: "sha256:\(githubSigner)"))
        ],
        lineage: [],
        guest: GuestFacts(sdk: 37, abis: ["arm64-v8a"]),
        lastCursor: lastCursor)
}

@Test func githubCheckPicksTheNewestStableRelease() async throws {
    // V2 is tagged "v0.1" — the tag is never a version; the newest
    // non-draft, non-prerelease release wins.
    let server = try UpdateServer.start(root: updateReposRoot())
    let checked = try await githubProvider(server).check(
        installedGitHubPackage(), context: githubContext(root: server.root))
    let candidate = try #require(checked)
    // §4.6: tag/name are never versions.
    #expect(candidate.declaredVersionCode == nil)
    #expect(candidate.declaredVersionName == nil)
    #expect(candidate.cursor.type == .github)
    // arm64-v8a asset preferred over universal; the digest is the hash.
    #expect(candidate.artifacts.count == 1)
    #expect(candidate.artifacts[0].sha256 != nil)
}

@Test func githubCheckSendsIfNoneMatchAndHonors304() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let provider = try githubProvider(server)
    let context = githubContext(root: server.root)
    let first = try #require(
        try await provider.check(installedGitHubPackage(), context: context))
    // The saved cursor carries the listing ETag; the next check revalidates.
    let second = try await provider.check(
        installedGitHubPackage(lastCursor: first.cursor), context: context)
    #expect(second == nil)
}

@Test func githubCheckPicksThePrereleaseOnThePrereleaseChannel() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let checked = try await githubProvider(server, spec: "octo/hello@prerelease")
        .check(installedGitHubPackage(), context: githubContext(root: server.root))
    #expect(try #require(checked).cursor.value.contains(":25:"))
}

@Test func githubCheckReportsAmbiguousAssets() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    do {
        _ = try await githubProvider(server, spec: "octo/ambiguous")
            .check(installedGitHubPackage(), context: githubContext(root: server.root))
        Issue.record("expected ambiguousAsset")
    } catch let failure as UpdateFailure {
        guard case .ambiguousAsset(let detail) = failure else {
            Issue.record("expected ambiguousAsset, got \(failure)")
            return
        }
        #expect(detail.contains("app-a.apk") && detail.contains("app-b.apk"))
    }
}

@Test func githubCheckReportsNoDigestWithoutAHash() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let candidate = try #require(
        try await githubProvider(server, spec: "octo/nodigest")
            .check(installedGitHubPackage(), context: githubContext(root: server.root)))
    #expect(candidate.artifacts[0].sha256 == nil)
}

@Test func githubCheckMapsAnExhaustedLimitToRateLimited() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let provider = try GitHubProvider(
        ref: GitHubProvider.providerRef(for: "octo/hello"),
        apiBase: server.baseURL.appendingPathComponent("github-limited"))
    do {
        _ = try await provider.check(
            installedGitHubPackage(), context: githubContext(root: server.root))
        Issue.record("expected providerRateLimited")
    } catch let failure as UpdateFailure {
        guard case .providerRateLimited = failure else {
            Issue.record("expected providerRateLimited, got \(failure)")
            return
        }
    }
}

@Test func githubCheckSendsTheTokenToTheAPIHost() async throws {
    let server = try UpdateServer.start(root: updateReposRoot())
    let provider = try GitHubProvider(
        ref: GitHubProvider.providerRef(for: "octo/hello"),
        apiBase: server.baseURL.appendingPathComponent("github-needauth"))
    // Without a token the listing answers 403; with one it answers the
    // releases JSON.
    let checked = try await provider.check(
        installedGitHubPackage(),
        context: githubContext(root: server.root, token: "tok-123"))
    #expect(checked != nil)
}

@Test func githubCheckDropsTheTokenAcrossARedirectHost() async throws {
    // /github/repos/redirect/x/releases answers 302 to the same server on
    // "localhost" — a different host — where the probe only replies when
    // no Authorization header survives.
    let server = try UpdateServer.start(root: updateReposRoot())
    let provider = try GitHubProvider(
        ref: GitHubProvider.providerRef(for: "redirect/x"),
        apiBase: server.baseURL.appendingPathComponent("github"))
    let checked = try await provider.check(
        installedGitHubPackage(),
        context: githubContext(root: server.root, token: "tok-123"))
    #expect(checked != nil)
}
