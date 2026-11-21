import APKStoreCore
import DiagnosticsCore
import Foundation

/// The GitHub release provider (update-system.md §4.6). The newest matching
/// release asset becomes the candidate; the tag is never a version — the
/// downloaded APK's versionCode and signer decide (FR-UPD-14). An optional
/// token lives only in the Keychain and is sent only to the API host.
public struct GitHubProvider: UpdateProvider {
    /// The public REST API base.
    public static let apiBaseURLString = "https://api.github.com"
    /// The Keychain service the token is stored under (§4.6).
    public static let tokenService = "io.apkrun.provider.github"
    /// The releases listing body cap.
    static let listingByteLimit: Int64 = 4_194_304
    /// The total download cap (§5.3).
    static let downloadByteLimit: Int64 = 8_589_934_592
    /// Release notes cap (§12).
    static let releaseNotesByteLimit = 16_384

    /// The provider identity stored on the package record.
    public var ref: UpdateProviderRef
    /// `owner/name`.
    let repository: String
    /// The asset-name glob.
    let assetPattern: String
    /// The release channel.
    let channel: GitHubReleaseChannel
    /// The API base; `api.github.com` outside tests and debug builds.
    let apiBase: URL
    /// `io.apkrun.update`/`provider` logging — hosts only, never a path or
    /// query (§8).
    private let log = APKLogger(category: UpdateLogCategory.provider)

    /// Creates a provider for a stored `{type:github}` reference against the
    /// public API.
    public init(ref: UpdateProviderRef) throws(UpdateFailure) {
        guard let apiBase = URL(string: Self.apiBaseURLString) else {
            throw .providerNotConfigured
        }
        try self.init(ref: ref, apiBase: apiBase)
    }

    /// Creates a provider against a custom API base; only the loopback base
    /// of the Debug update-server is ever allowed besides `api.github.com`.
    init(ref: UpdateProviderRef, apiBase: URL) throws(UpdateFailure) {
        guard case .github(let repository, let assetPattern, let channel) = ref.configuration
        else {
            throw .providerNotConfigured
        }
        guard Self.isAllowed(apiBase) else {
            throw .providerNotConfigured
        }
        self.ref = ref
        self.repository = repository
        self.assetPattern = assetPattern
        self.channel = channel
        self.apiBase = apiBase
    }

    /// `https` only, or loopback `http` in debug builds (§8).
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host != nil else { return false }
        if scheme == "https" { return true }
        #if DEBUG
            if scheme == "http",
                let host = url.host?.lowercased(),
                host == "127.0.0.1" || host == "localhost"
            {
                return true
            }
        #endif
        return false
    }

    /// The stored reference a `github:<owner>/<name>[:<glob>][@prerelease]`
    /// spec produces (§4.6, runtime-api.md §9.2).
    public static func providerRef(for body: String) throws(UpdateFailure) -> UpdateProviderRef {
        let configuration = try GitHubConfiguration(spec: body)
        return UpdateProviderRef(
            type: .github,
            configuration: .github(
                repository: configuration.repository,
                assetPattern: configuration.assetPattern,
                channel: configuration.channel))
    }

    /// The `GET /repos/{owner}/{name}/releases` URL (§4.6); nil only if
    /// `apiBase` is malformed, which `isAllowed` rules out at init.
    var releasesURL: URL? {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("repos/\(repository)/releases"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: "10")]
        return components?.url
    }

    /// The request headers of §4.6; `Authorization` appears only when a
    /// token is stored, and only on requests to the API base — the token
    /// reaches no other host.
    private func headers(
        context: ProviderContext, etag: String? = nil, download: Bool = false
    ) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
        if download {
            headers["Accept"] = "application/octet-stream"
        }
        if let etag {
            headers["If-None-Match"] = etag
        }
        if !download, let token = context.credentials.token(for: Self.tokenService) {
            headers["Authorization"] = "Bearer \(token)"
        }
        return headers
    }

    /// The parsed cursor: `<etag>\t<releaseID>:<assetID>:<updated_at>:<size>`.
    private func cursorValue(etag: String, release: Release, asset: Release.Asset) -> String {
        "\(etag)\t\(release.id):\(asset.id):\(asset.updatedAt ?? ""):\(asset.size ?? 0)"
    }

    /// Maps a response to its §4.6 failure: a `403`/`429` with an exhausted
    /// rate budget is `providerRateLimited` with `x-ratelimit-reset`; other
    /// statuses follow the shared mapping.
    private static func failure(
        status: Int, remaining: Int?, reset: TimeInterval?, retryAfter: TimeInterval?
    ) -> UpdateFailure {
        if status == 403 || status == 429, remaining == 0 {
            return .providerRateLimited(retryAfter: reset ?? retryAfter)
        }
        return DirectProvider.statusFailure(status, retryAfter: retryAfter)
    }

    /// `check` (§4.6): read the release listing with `If-None-Match`, choose
    /// the newest eligible release and the matching asset. The chosen
    /// asset's cursor prevents a second download of a non-newer asset.
    public func check(
        _ package: InstalledPackage,
        context: ProviderContext
    ) async throws(UpdateFailure) -> UpdateCandidate? {
        // The cursor's first segment is the last listing ETag. A
        // user-initiated check refetches in full so a candidate that was
        // only shown can still be applied.
        var etag: String?
        if !context.userInitiated, let cursor = package.lastCursor,
            cursor.type == .github,
            let separator = cursor.value.firstIndex(of: "\t")
        {
            let stored = String(cursor.value[..<separator])
            if !stored.isEmpty { etag = stored }
        }
        log.debug("github releases check host=\(apiBase.host ?? "-", .public)")
        guard let releasesURL else { throw .providerNotConfigured }
        let response = try await context.http.get(
            releasesURL,
            headers: headers(context: context, etag: etag),
            byteLimit: Self.listingByteLimit)
        if response.status == 304 { return nil }
        guard (200...299).contains(response.status) else {
            throw Self.failure(
                status: response.status,
                remaining: response.rateLimitRemaining,
                reset: response.rateLimitReset,
                retryAfter: response.retryAfter)
        }
        let releases = try Self.decodeReleases(response.body)
        guard
            let release = releases.first(where: {
                !$0.draft && (channel == .prerelease || !$0.prerelease)
            })
        else {
            return nil
        }
        let asset = try chooseAsset(in: release)
        guard let artifactURL = URL(string: asset.browserDownloadURL),
            Self.isAllowed(artifactURL), artifactURL.user == nil,
            artifactURL.password == nil
        else {
            throw .providerMetadataInvalid(
                detail: "asset: browser_download_url is not an allowed URL")
        }
        let listingTag =
            response.etag ?? "sha256:\(APKStoreCore.SHA256Digest(data: response.body).hexValue)"
        let cursor = ProviderCursor(
            type: .github, value: cursorValue(etag: listingTag, release: release, asset: asset))
        if !context.userInitiated, package.lastCursor == cursor {
            return nil
        }
        return UpdateCandidate(
            packageID: package.id,
            provider: ref,
            artifacts: [
                RemoteArtifact(
                    url: artifactURL,
                    kind: Self.kind(of: asset.name),
                    sha256: Self.assetDigest(asset.digest),
                    size: asset.size)
            ],
            releaseNotes: release.body.map(Self.releaseNotes),
            publishedAt: release.publishedAt.flatMap(Self.rfc3339),
            cursor: cursor)
    }

    /// `download` (§4.6, §5.3): stream each artifact hashing while writing,
    /// verify the declared `digest` when present, retry a mismatch once from
    /// scratch. Redirects carry no `Authorization` (the transport strips it)
    /// and the token never leaves the API host.
    public func download(
        _ candidate: UpdateCandidate,
        to destination: DownloadDestination,
        context: ProviderContext,
        progress: @Sendable (DownloadProgress) -> Void
    ) async throws(UpdateFailure) -> PackageArtifact {
        var written: Int64 = 0
        let declaredTotal = candidate.artifacts.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var downloaded: [RemoteArtifact] = []
        for artifact in candidate.artifacts {
            let file = destination.directory.appendingPathComponent(
                artifact.url.lastPathComponent)
            for attempt in 1...2 {
                let limit = artifact.size ?? (Self.downloadByteLimit - written)
                let response = try await context.http.download(
                    artifact.url,
                    headers: headers(context: context, download: true),
                    into: file, byteLimit: limit)
                guard (200...299).contains(response.status) else {
                    throw Self.failure(
                        status: response.status,
                        remaining: response.rateLimitRemaining,
                        reset: response.rateLimitReset,
                        retryAfter: response.retryAfter)
                }
                let ok =
                    !response.limitHit
                    && (artifact.size == nil || response.bytesWritten == artifact.size)
                    && (artifact.sha256 == nil || response.sha256 == artifact.sha256)
                if ok {
                    if written + response.bytesWritten > Self.downloadByteLimit {
                        throw .tooLarge(
                            bytes: written + response.bytesWritten,
                            limit: Self.downloadByteLimit)
                    }
                    written += response.bytesWritten
                    var copy = artifact
                    copy.url = file
                    downloaded.append(copy)
                    progress(
                        DownloadProgress(
                            bytesWritten: written,
                            bytesTotal: declaredTotal > 0 ? declaredTotal : nil))
                    break
                }
                try? FileManager.default.removeItem(at: file)
                if attempt == 2 {
                    throw .hashMismatch(artifact: artifact.url.absoluteString)
                }
            }
        }

        if downloaded.count == 1, downloaded[0].kind == .container {
            return .container(downloaded[0].url)
        }
        guard let base = downloaded.first(where: { $0.kind == .apk }) else {
            throw .providerMetadataInvalid(detail: "downloaded set has no base APK")
        }
        let splits = downloaded.filter { $0.kind != .apk }.map(\.url)
        if splits.isEmpty {
            return .apk(base.url)
        }
        return .splitSet(base: base.url, splits: splits)
    }

    /// The one §2.3 test request of `setUpdatePolicy`: fetch the release
    /// listing so a wrong repository or token fails before anything writes.
    public func testConnection(context: ProviderContext) async throws(UpdateFailure) {
        guard let releasesURL else { throw .providerNotConfigured }
        let response = try await context.http.get(
            releasesURL,
            headers: headers(context: context),
            byteLimit: Self.listingByteLimit)
        guard (200...299).contains(response.status) else {
            throw Self.failure(
                status: response.status,
                remaining: response.rateLimitRemaining,
                reset: response.rateLimitReset,
                retryAfter: response.retryAfter)
        }
        _ = try Self.decodeReleases(response.body)
    }

    /// The asset choice of §4.6: names matching `assetPattern`, preferring
    /// `arm64-v8a`/`arm64`, then `universal`; several survivors are
    /// `ambiguousAsset`.
    private func chooseAsset(in release: Release) throws(UpdateFailure) -> Release.Asset {
        var matches = release.assets.filter {
            Glob(assetPattern).matches($0.name)
        }
        for hint in [["arm64-v8a", "arm64"], ["universal"]] {
            let hinted = matches.filter { name in
                hint.contains { name.name.range(of: $0, options: .caseInsensitive) != nil }
            }
            if !hinted.isEmpty { matches = hinted }
            if matches.count <= 1 { break }
        }
        guard let asset = matches.first else {
            throw .providerMetadataInvalid(
                detail: "release \(release.tagName): no asset matches \(assetPattern)")
        }
        guard matches.count == 1 else {
            throw .ambiguousAsset(
                detail: matches.map(\.name).sorted().joined(separator: ", "))
        }
        return asset
    }

    /// The asset's declared SHA-256 from `digest` (`sha256:<hex>`); other
    /// algorithms and a missing digest leave the hash nil (§4.6).
    static func assetDigest(_ digest: String?) -> APKStoreCore.SHA256Digest? {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return nil }
        return APKStoreCore.SHA256Digest(
            hex: String(digest.dropFirst("sha256:".count)).lowercased())
    }

    /// The artifact kind from the asset file name.
    private static func kind(of name: String) -> RemoteArtifactKind {
        let lower = name.lowercased()
        if lower.hasSuffix(".apks") || lower.hasSuffix(".xapk") || lower.hasSuffix(".apkm") {
            return .container
        }
        return .apk
    }

    /// Release notes shown as plain text: capped at 16 KiB, terminal-affecting
    /// characters stripped (§12).
    private static func releaseNotes(_ body: String) -> String {
        let stripped = String(
            body.unicodeScalars.filter {
                ![.control, .format].contains($0.properties.generalCategory)
                    || $0 == "\n" || $0 == "\r" || $0 == "\t"
            })
        if stripped.utf8.count <= releaseNotesByteLimit { return stripped }
        var cut = String()
        cut.reserveCapacity(releaseNotesByteLimit)
        for scalar in stripped.unicodeScalars {
            if cut.utf8.count + scalar.utf8.count > releaseNotesByteLimit { break }
            cut.unicodeScalars.append(scalar)
        }
        return cut
    }

    /// RFC 3339 `published_at`/`updated_at` parsing.
    private static func rfc3339(_ value: String) -> Date? {
        for options in [
            ISO8601DateFormatter.Options.withInternetDateTime,
            [.withInternetDateTime, .withFractionalSeconds],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    /// The release-listing JSON model; every field is untrusted input.
    struct Release: Decodable {
        var id: Int64
        var draft: Bool
        var prerelease: Bool
        var tagName: String
        var body: String?
        var publishedAt: String?
        var assets: [Asset]

        struct Asset: Decodable {
            var id: Int64
            var name: String
            var size: Int64?
            var digest: String?
            var browserDownloadURL: String
            var updatedAt: String?

            private enum CodingKeys: String, CodingKey {
                case id, name, size, digest
                case browserDownloadURL = "browser_download_url"
                case updatedAt = "updated_at"
            }
        }

        private enum CodingKeys: String, CodingKey {
            case id, draft, prerelease, body, assets
            case tagName = "tag_name"
            case publishedAt = "published_at"
        }
    }

    /// Decodes the listing; malformed JSON is `providerMetadataInvalid`.
    private static func decodeReleases(_ body: Data) throws(UpdateFailure) -> [Release] {
        do {
            return try JSONDecoder().decode([Release].self, from: body)
        } catch {
            throw .providerMetadataInvalid(detail: "releases: not a GitHub release listing")
        }
    }
}

/// The `github:` spec configuration (update-system.md §4.6):
/// `github:<owner>/<name>[:<asset-glob>][@prerelease]`.
public struct GitHubConfiguration: Sendable, Hashable {
    /// `owner/name`.
    public var repository: String
    /// The asset-name glob; `*.apk` when the spec carries none.
    public var assetPattern: String
    /// The release channel.
    public var channel: GitHubReleaseChannel

    /// Parses the spec body after `github:`.
    /// - Throws: `providerMetadataInvalid` on a malformed spec.
    public init(spec body: String) throws(UpdateFailure) {
        var rest = body
        var channel = GitHubReleaseChannel.stable
        if rest.hasSuffix("@prerelease") {
            channel = .prerelease
            rest = String(rest.dropLast("@prerelease".count))
        } else if rest.contains("@") {
            throw .providerMetadataInvalid(
                detail: "github spec: unknown channel; only @prerelease is defined")
        }
        let segments = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let repository = String(segments[0])
        let assetPattern =
            segments.count == 2 ? String(segments[1]) : "*.apk"
        guard Self.isRepository(repository) else {
            throw .providerMetadataInvalid(
                detail: "github spec needs <owner>/<name>")
        }
        guard Self.isAssetPattern(assetPattern) else {
            throw .providerMetadataInvalid(
                detail: "github spec: asset glob is empty, over 255 bytes, or holds a \"/\"")
        }
        self.repository = repository
        self.assetPattern = assetPattern
        self.channel = channel
    }

    /// `owner/name` per GitHub naming: owner is 1–39 alphanumerics or
    /// hyphens not starting or ending with a hyphen; the name is 1–100 of
    /// alphanumerics, `.`, `_`, `-`.
    static func isRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let owner = parts[0]
        let name = parts[1]
        guard (1...39).contains(owner.count),
            owner.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }),
            owner.first != "-", owner.last != "-"
        else {
            return false
        }
        guard (1...100).contains(name.count),
            name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }),
            name != ".", name != ".."
        else {
            return false
        }
        return true
    }

    /// An asset glob is 1–255 bytes without a `/` or control characters.
    static func isAssetPattern(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, !value.contains("/") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            ![.control, .format].contains($0.properties.generalCategory)
        }
    }
}

/// A shell-style `*`/`?` glob over asset names (§4.6).
public struct Glob: Sendable, Hashable {
    /// The pattern text.
    public let pattern: String

    /// Creates a glob.
    public init(_ pattern: String) {
        self.pattern = pattern
    }

    /// True when `name` matches the whole pattern: `*` spans any run
    /// (including an empty one), `?` exactly one character.
    public func matches(_ name: String) -> Bool {
        let pattern = Array(self.pattern)
        let name = Array(name)
        // A `*` also matches the empty run, so the automaton may pass it
        // without consuming a character.
        func expand(_ states: Set<Int>) -> Set<Int> {
            var result = states
            var queue = Array(states)
            while let position = queue.popLast() {
                if position < pattern.count, pattern[position] == "*",
                    !result.contains(position + 1)
                {
                    result.insert(position + 1)
                    queue.append(position + 1)
                }
            }
            return result
        }
        var states = expand([0])
        for character in name {
            var next = Set<Int>()
            for position in states {
                guard position < pattern.count else { continue }
                if pattern[position] == "*" {
                    // The star consumes this character and stays.
                    next.insert(position)
                } else if pattern[position] == "?" || pattern[position] == character {
                    next.insert(position + 1)
                }
            }
            states = expand(next)
        }
        return states.contains(pattern.count)
    }
}
