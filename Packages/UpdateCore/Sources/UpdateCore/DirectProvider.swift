import APKStoreCore
import Foundation

/// The Codable model of `direct-provider-manifest.md`. The published JSON
/// Schema (docs/03-reference/schemas/direct-provider-manifest.schema.json)
/// defines structure; `check` below applies the reader rules D1–D9.
public struct DirectManifest: Codable, Sendable {
    /// The format version; only 1 is defined.
    public var schemaVersion: Int
    /// The Android package name.
    public var packageId: String
    /// Android `longVersionCode`.
    public var versionCode: Int64
    /// Display version name.
    public var versionName: String?
    /// The release's files.
    public var artifacts: [Artifact]
    /// `sha256:` + 64 lowercase hex per signing certificate.
    public var signingCertificates: [String]?
    /// Declared `minSdkVersion`; a pre-filter only.
    public var minSdk: Int?
    /// Plain-text release notes.
    public var releaseNotes: String?
    /// RFC 3339 release time.
    public var publishedAt: String?

    /// One release file.
    public struct Artifact: Codable, Sendable {
        /// `apk`, `split`, or `apks`.
        public var type: String
        /// Absolute https URL or a reference relative to the manifest URL.
        public var url: String
        /// 64 hex digits, either case.
        public var sha256: String
        /// Declared size in bytes.
        public var size: Int64?
        /// The Android split name; required for `split` only.
        public var splitName: String?
    }
}

/// The HTTPS manifest provider of direct-provider-manifest.md
/// (update-system.md §4.4). The APK decides (FR-UPD-14): manifest data can
/// only cause a refusal, never an acceptance.
public struct DirectProvider: UpdateProvider {
    /// The manifest body cap (rule D1).
    static let manifestByteLimit = 1_048_576
    /// The total download cap (rule D7, §5.3).
    static let downloadByteLimit: Int64 = 8_589_934_592
    /// Release notes cap (rule D8).
    static let releaseNotesByteLimit = 16_384

    /// The provider identity stored on the package record.
    public var ref: UpdateProviderRef
    /// The manifest URL from the stored configuration.
    let manifestURL: URL

    /// Creates a provider for a stored `{type:direct, url:…}` reference.
    public init(ref: UpdateProviderRef) throws(UpdateFailure) {
        guard case .direct(let urlString) = ref.configuration,
            let url = URL(string: urlString),
            Self.isAllowed(url)
        else {
            throw .providerNotConfigured
        }
        self.ref = ref
        manifestURL = url
    }

    /// `https`, or loopback `http` in debug builds (§5.1, §8).
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

    /// Fetches and validates the manifest (§5.1, §6.2 rules D1–D9).
    public func check(
        _ package: InstalledPackage,
        context: ProviderContext
    ) async throws(UpdateFailure) -> UpdateCandidate? {
        var headers: [String: String] = [:]
        // The cursor scopes its ETag to the manifest URL: a provider spec
        // pointing at a different URL never sends the old URL's ETag
        // (a 304 there would hide the new source's release). A
        // user-initiated check refetches in full so a candidate that was
        // only shown can still be applied.
        if !context.userInitiated, let cursor = package.lastCursor, cursor.type == .direct,
            let separator = cursor.value.firstIndex(of: "\t"),
            String(cursor.value[..<separator]) == manifestURL.absoluteString
        {
            headers["If-None-Match"] = String(cursor.value[cursor.value.index(after: separator)...])
        }
        let response = try await context.http.get(
            manifestURL, headers: headers, byteLimit: Int64(Self.manifestByteLimit))
        if response.status == 304 { return nil }
        guard (200...299).contains(response.status) else {
            throw Self.statusFailure(response.status, retryAfter: response.retryAfter)
        }

        // D1: at most 1 MiB of valid UTF-8 JSON.
        guard response.body.count <= Self.manifestByteLimit else {
            throw .providerMetadataInvalid(detail: "body: over 1 MiB")
        }
        guard String(data: response.body, encoding: .utf8) != nil else {
            throw .providerMetadataInvalid(detail: "body: not UTF-8")
        }
        let manifest: DirectManifest
        do {
            manifest = try JSONDecoder().decode(DirectManifest.self, from: response.body)
        } catch {
            throw .providerMetadataInvalid(detail: "body: not a Direct manifest (\(error))")
        }

        // D2: only schemaVersion 1 is defined.
        guard manifest.schemaVersion == 1 else {
            throw .providerMetadataInvalid(
                detail: "unsupported schemaVersion \(manifest.schemaVersion); update APKRun")
        }

        // D3: the schema's field constraints the decoder cannot express.
        guard PackageID(rawValue: manifest.packageId) != nil else {
            throw .providerMetadataInvalid(detail: "packageId: not a package name")
        }
        guard manifest.versionCode >= 1 else {
            throw .providerMetadataInvalid(detail: "versionCode: must be ≥ 1")
        }
        if let name = manifest.versionName, name.isEmpty || name.utf8.count > 255 {
            throw .providerMetadataInvalid(detail: "versionName: 1–255 characters")
        }
        guard (1...256).contains(manifest.artifacts.count) else {
            throw .providerMetadataInvalid(detail: "artifacts: 1–256 items")
        }
        if let signers = manifest.signingCertificates {
            guard (1...16).contains(signers.count),
                signers.allSatisfy({ SHA256Digest(rawValue: $0) != nil }),
                Set(signers).count == signers.count
            else {
                throw .providerMetadataInvalid(
                    detail: "signingCertificates: 1–16 unique sha256 digests")
            }
        }
        if let minSdk = manifest.minSdk, !(1...10_000).contains(minSdk) {
            throw .providerMetadataInvalid(detail: "minSdk: 1–10000")
        }
        if let notes = manifest.releaseNotes {
            guard notes.utf8.count <= Self.releaseNotesByteLimit, notes.count <= 16_384 else {
                throw .providerMetadataInvalid(detail: "releaseNotes: over 16 KiB")
            }
        }
        // Artifact-object constraints (schema §3.2).
        for (index, artifact) in manifest.artifacts.enumerated() {
            guard ["apk", "split", "apks"].contains(artifact.type) else {
                throw .providerMetadataInvalid(
                    detail: "artifacts[\(index)].type: \(artifact.type) is not allowed")
            }
            guard SHA256Digest(hex: artifact.sha256.lowercased()) != nil else {
                throw .providerMetadataInvalid(
                    detail: "artifacts[\(index)].sha256: not 64 hex digits")
            }
            if let size = artifact.size, size < 1 || size > Self.downloadByteLimit {
                throw .providerMetadataInvalid(
                    detail: "artifacts[\(index)].size: 1–8 GiB")
            }
            if artifact.type != "apks",
                let size = artifact.size, size > 2_147_483_648
            {
                throw .providerMetadataInvalid(
                    detail: "artifacts[\(index)].size: over 2 GiB")
            }
            switch artifact.type {
            case "split":
                guard let name = artifact.splitName,
                    Self.isSplitName(name)
                else {
                    throw .providerMetadataInvalid(
                        detail: "artifacts[\(index)].splitName: required, segment grammar")
                }
            default:
                guard artifact.splitName == nil else {
                    throw .providerMetadataInvalid(
                        detail: "artifacts[\(index)].splitName: forbidden for \(artifact.type)")
                }
            }
        }
        // §4: exactly one artifact shape is valid.
        let kinds = manifest.artifacts.map(\.type)
        // The schema orders nothing: one `apk` plus `split` artifacts in
        // any order, or a single `apks` container.
        let shapeOK =
            kinds == ["apk"]
            || (kinds.filter { $0 == "apk" }.count == 1
                && kinds.allSatisfy { $0 == "apk" || $0 == "split" })
            || kinds == ["apks"]
        guard shapeOK else {
            throw .providerMetadataInvalid(
                detail: "artifacts: not a valid apk / apk+splits / apks combination")
        }

        // D4: the manifest's package equals the attached package.
        guard manifest.packageId == package.id.rawValue else {
            throw .providerMetadataInvalid(
                detail: "packageId: \(manifest.packageId) != \(package.id.rawValue)")
        }

        // D5: every artifact URL resolves to an allowed URL without user info,
        // against the *final* manifest URL (§5.2).
        let base = response.finalURL ?? manifestURL
        var resolved: [URL] = []
        resolved.reserveCapacity(manifest.artifacts.count)
        for (index, artifact) in manifest.artifacts.enumerated() {
            guard let url = URL(string: artifact.url, relativeTo: base)?.absoluteURL else {
                throw .providerMetadataInvalid(
                    detail: "artifacts[\(index)].url: not a URL")
            }
            guard Self.isAllowed(url) else {
                throw .providerMetadataInvalid(
                    detail: "artifacts[\(index)].url: \(url.scheme ?? "none") is not allowed")
            }
            guard url.user == nil, url.password == nil else {
                throw .providerMetadataInvalid(
                    detail: "artifacts[\(index)].url: user info is not allowed")
            }
            resolved.append(url)
        }

        // D6: split names and resolved URLs are unique.
        let splitNames = manifest.artifacts.compactMap(\.splitName)
        guard Set(splitNames).count == splitNames.count else {
            throw .providerMetadataInvalid(detail: "artifacts: duplicate splitName")
        }
        guard Set(resolved).count == resolved.count else {
            throw .providerMetadataInvalid(detail: "artifacts: duplicate url")
        }

        // D7: declared sizes sum to at most 8 GiB.
        let declaredTotal = manifest.artifacts.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        guard declaredTotal <= Self.downloadByteLimit else {
            throw .providerMetadataInvalid(detail: "artifacts: sizes exceed 8 GiB")
        }

        // D8: release notes UTF-8 cap (checked above with D3 constraints).

        // D9: not newer → no candidate; too-new SDK → no compatible artifact.
        guard manifest.versionCode > package.versionCode else {
            return nil
        }
        if let minSdk = manifest.minSdk, minSdk > package.guest.sdk {
            throw .noCompatibleArtifact(.sdkTooLow)
        }

        let cursor = ProviderCursor(
            type: .direct,
            value:
                "\(manifestURL.absoluteString)\t\(response.etag ?? "sha256:\(SHA256Digest(data: response.body).hexValue)")"
        )
        if !context.userInitiated, package.lastCursor == cursor {
            return nil
        }

        return UpdateCandidate(
            packageID: package.id,
            provider: ref,
            declaredVersionCode: manifest.versionCode,
            declaredVersionName: manifest.versionName.map(Self.sanitizedDisplay),
            declaredSignerDigests: manifest.signingCertificates?
                .compactMap { SHA256Digest(rawValue: $0.lowercased()) },
            artifacts: zip(manifest.artifacts, resolved).map { artifact, url in
                RemoteArtifact(
                    url: url,
                    kind: Self.kind(of: artifact),
                    sha256: SHA256Digest(hex: artifact.sha256.lowercased()),
                    size: artifact.size)
            },
            releaseNotes: manifest.releaseNotes,
            publishedAt: manifest.publishedAt.flatMap(Self.rfc3339),
            cursor: cursor)
    }

    /// Downloads every artifact, hashing while streaming (§5.3): one retry on
    /// hash mismatch, then `hashMismatch`; the byte sum is capped at 8 GiB.
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
            let file = destination.directory.appendingPathComponent(fileName(of: artifact))
            for attempt in 1...2 {
                // Byte limit: the declared size; an extra byte stops the
                // stream and counts as a mismatch. Without a declaration,
                // the remaining 8 GiB budget applies.
                let limit = artifact.size ?? (Self.downloadByteLimit - written)
                let response = try await context.http.download(
                    artifact.url, headers: [:], into: file, byteLimit: limit)
                guard (200...299).contains(response.status) else {
                    throw Self.statusFailure(response.status, retryAfter: response.retryAfter)
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

    /// The on-disk name is the artifact URL's last path component, the same
    /// name the coordinator's hash check looks up (LocalProvider does the
    /// same). A URL ending without a usable name falls back per kind.
    private func fileName(of artifact: RemoteArtifact) -> String {
        let name = artifact.url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            switch artifact.kind {
            case .apk: return "base.apk"
            case .split(let name): return "split_\(name).apk"
            case .container: return "container.apks"
            }
        }
        return name
    }

    /// Strips terminal-affecting characters from a manifest string before
    /// it reaches `apkrun update` output (control and format categories).
    private static func sanitizedDisplay(_ value: String) -> String {
        String(
            value.unicodeScalars.filter {
                ![.control, .format].contains($0.properties.generalCategory)
            })
    }

    /// Maps a status to its failure (§5.1).
    static func statusFailure(_ status: Int, retryAfter: TimeInterval?) -> UpdateFailure {
        if status == 429 || (status == 503 && retryAfter != nil) {
            return .providerRateLimited(retryAfter: retryAfter)
        }
        return .providerHTTPStatus(status)
    }

    /// The manifest `type` to the artifact kind.
    private static func kind(of artifact: DirectManifest.Artifact) -> RemoteArtifactKind {
        switch artifact.type {
        case "apk": .apk
        case "split": .split(artifact.splitName ?? "")
        default: .container
        }
    }

    /// The split-name grammar (schema §3.2).
    private static func isSplitName(_ name: String) -> Bool {
        name.utf8.count <= 255
            && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { segment in
                guard let first = segment.first, first.isLetter else { return false }
                return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }
    }

    /// RFC 3339 `date-time` with a time zone (§3.1).
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
}
