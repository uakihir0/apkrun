import APKStoreCore
import DiagnosticsCore
import Foundation

/// The signed F-Droid v2 repository provider (update-system.md §4.5). The
/// index signature is checked by `FDroidIndexVerifier` against a pinned
/// signing-certificate fingerprint; the index is cached and diff-updated by
/// `FDroidIndexReader`; the APK decides the update (FR-UPD-14).
public struct FDroidProvider: UpdateProvider {
    /// The main repository's URL.
    public static let mainRepository = "https://f-droid.org/repo"
    /// The main repository's pinned signing-certificate SHA-256 (§4.5).
    public static let mainFingerprint =
        "43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab"
    /// The `entry.jar` download cap; the archive itself is held to 16 MiB.
    static let entryByteLimit: Int64 = 16 * 1024 * 1024
    /// One index file download cap (same as the decode budget).
    static let indexByteLimit: Int64 = Int64(FDroidIndexReader.indexByteLimit)

    /// The provider identity stored on the package record.
    public var ref: UpdateProviderRef
    /// The repository base URL (`<repo>/entry.jar`, `<repo>/<file.name>`).
    let repository: URL
    /// The pinned signing-certificate SHA-256.
    let fingerprint: APKStoreCore.SHA256Digest
    /// `io.apkrun.update`/`provider` logging — hosts only, never a path or
    /// query (§8).
    private let log = APKLogger(category: UpdateLogCategory.provider)

    /// Creates a provider for a stored `{type:fdroid}` reference.
    public init(ref: UpdateProviderRef) throws(UpdateFailure) {
        guard case .fdroid(let repository, let fingerprint) = ref.configuration,
            let url = URL(string: repository), Self.isAllowed(url),
            let pinned = APKStoreCore.SHA256Digest(hex: fingerprint)
        else {
            throw .providerNotConfigured
        }
        self.ref = ref
        self.repository = url
        self.fingerprint = pinned
    }

    /// `https`, or loopback `http` in debug builds (§8).
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

    /// The stored reference a `fdroid[:<url>#<fingerprint>]` spec produces
    /// (§4.5, runtime-api.md §9.2). A bare `fdroid` names the main repository
    /// with its pinned fingerprint; another repository needs its own.
    public static func providerRef(for body: String) throws(UpdateFailure) -> UpdateProviderRef {
        if body.isEmpty {
            return UpdateProviderRef(
                type: .fdroid,
                configuration: .fdroid(
                    repository: Self.mainRepository, fingerprint: Self.mainFingerprint))
        }
        guard let separator = body.lastIndex(of: "#") else {
            throw .providerMetadataInvalid(
                detail: "fdroid spec needs <url>#<fingerprint>, or bare \"fdroid\"")
        }
        let urlString = String(body[..<separator])
        let fingerprint = String(body[body.index(after: separator)...])
        guard urlString.utf8.count <= 2048, let url = URL(string: urlString), isAllowed(url) else {
            throw .providerMetadataInvalid(detail: "fdroid repository URL must be https")
        }
        guard url.user == nil, url.password == nil else {
            throw .providerMetadataInvalid(
                detail: "fdroid repository URL must not carry user info")
        }
        guard APKStoreCore.SHA256Digest(hex: fingerprint) != nil else {
            throw .providerMetadataInvalid(detail: "fdroid fingerprint is not a SHA-256 hex digest")
        }
        return UpdateProviderRef(
            type: .fdroid,
            configuration: .fdroid(
                repository: urlString, fingerprint: fingerprint.lowercased()))
    }

    /// Fetches and verifies `entry.jar`; used by `setUpdatePolicy`'s one
    /// test request (§2.3) and by `check`.
    /// - Throws: the verification failure.
    public func fetchEntry(context: ProviderContext) async throws(UpdateFailure) -> FDroidEntry {
        let jarURL = repository.appendingPathComponent("entry.jar")
        let jarFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-fdroid-entry-\(UUID().uuidString).jar")
        defer { try? FileManager.default.removeItem(at: jarFile) }
        let response = try await context.http.download(
            jarURL, headers: [:], into: jarFile, byteLimit: Self.entryByteLimit)
        guard (200...299).contains(response.status), !response.limitHit else {
            if !(200...299).contains(response.status) {
                throw DirectProvider.statusFailure(
                    response.status, retryAfter: response.retryAfter)
            }
            throw .providerMetadataInvalid(detail: "entry.jar: over 16 MiB")
        }
        let entryData = try FDroidIndexVerifier.entryJSON(in: jarFile, fingerprint: fingerprint)
        guard let entry = try? JSONDecoder().decode(FDroidEntry.self, from: entryData) else {
            throw .providerMetadataInvalid(detail: "entry.json: not an F-Droid v2 entry")
        }
        try validate(entry.index)
        for file in entry.diffs.values { try validate(file) }
        return entry
    }

    /// The cached index directory key: `fdroid/<first 16 hex of
    /// SHA-256(repository)>` (§4.5).
    var cacheKey: String {
        let hex = APKStoreCore.SHA256Digest(data: Data(repository.absoluteString.utf8)).hexValue
        return "fdroid/\(hex.prefix(16))"
    }

    /// `check` (§4.5): fetch `entry.jar`, update the cached index — diff or
    /// full — and pick the highest compatible `versionCode`. Versions whose
    /// signer differs never install; that is recorded through
    /// `incompatibleNote` and the check still returns nil.
    public func check(
        _ package: InstalledPackage,
        context: ProviderContext
    ) async throws(UpdateFailure) -> UpdateCandidate? {
        let entry = try await fetchEntry(context: context)
        let reader = FDroidIndexReader()
        let indexData = try await updateIndex(entry: entry, reader: reader, context: context)
        let packages = try reader.packages(in: indexData, keep: [package.id])
        guard let fdroidPackage = packages[package.id], !fdroidPackage.versions.isEmpty else {
            return nil
        }

        let installedSigners = Set(package.signerDigests.map(\.hexValue))
        var best: (key: String, version: FDroidPackage.Version)?
        var sawCompatibleShape = false
        for (key, version) in fdroidPackage.versions {
            guard version.manifest.versionCode > package.versionCode else { continue }
            guard Self.abiFits(version.manifest.nativecode, abis: package.guest.abis) else {
                continue
            }
            guard (version.manifest.usesSdk?.minSdkVersion ?? 1) <= package.guest.sdk else {
                continue
            }
            if let maximum = version.manifest.maxSdkVersion, package.guest.sdk > maximum {
                continue
            }
            guard let signer = version.manifest.signer?.sha256, !signer.isEmpty else {
                continue
            }
            guard Set(signer.map { $0.lowercased() }) == installedSigners else {
                sawCompatibleShape = true
                continue
            }
            sawCompatibleShape = true
            if best == nil
                || version.manifest.versionCode > best!.version.manifest.versionCode
            {
                best = (key, version)
            }
        }
        guard let best else {
            // Versions exist but none matched the installed signer (§4.5):
            // no candidate, and the reason is recorded for the settings UI.
            if sawCompatibleShape {
                context.incompatibleNote?(.signerDiffers)
            }
            return nil
        }

        let version = best.version
        guard let fileSHA = version.file.sha256, APKStoreCore.SHA256Digest(hex: fileSHA) != nil else {
            throw .providerMetadataInvalid(detail: "index: chosen version has no file.sha256")
        }
        let artifactURL = repository.appendingPathComponent(version.file.name)
        guard Self.isAllowed(artifactURL) else {
            throw .providerMetadataInvalid(detail: "index: artifact URL is not allowed")
        }
        let cursor = ProviderCursor(
            type: .fdroid, value: "\(entry.timestamp):\(best.key)")
        return UpdateCandidate(
            packageID: package.id,
            provider: ref,
            declaredVersionCode: VersionCode(version.manifest.versionCode),
            declaredVersionName: version.manifest.versionName,
            declaredSignerDigests: version.manifest.signer?.sha256
                .compactMap { APKStoreCore.SHA256Digest(hex: $0.lowercased()) },
            artifacts: [
                RemoteArtifact(
                    url: artifactURL, kind: .apk,
                    sha256: APKStoreCore.SHA256Digest(hex: fileSHA.lowercased()),
                    size: version.file.size)
            ],
            publishedAt: nil,
            cursor: cursor)
    }

    /// Downloads the chosen artifact, hashing while streaming (§5); the
    /// declared SHA-256 is required, so a mismatch retries once then fails.
    public func download(
        _ candidate: UpdateCandidate,
        to destination: DownloadDestination,
        context: ProviderContext,
        progress: @Sendable (DownloadProgress) -> Void
    ) async throws(UpdateFailure) -> PackageArtifact {
        var written: Int64 = 0
        let declaredTotal = candidate.artifacts.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var downloaded: URL?
        for artifact in candidate.artifacts {
            let file = destination.directory.appendingPathComponent(
                artifact.url.lastPathComponent)
            for attempt in 1...2 {
                let limit = artifact.size ?? (Self.downloadSizeLimit - written)
                let response = try await context.http.download(
                    artifact.url, headers: [:], into: file, byteLimit: limit)
                guard (200...299).contains(response.status) else {
                    throw DirectProvider.statusFailure(
                        response.status, retryAfter: response.retryAfter)
                }
                let ok =
                    !response.limitHit
                    && (artifact.size == nil || response.bytesWritten == artifact.size)
                    && (artifact.sha256 == nil || response.sha256 == artifact.sha256)
                if ok {
                    written += response.bytesWritten
                    downloaded = file
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
        guard let downloaded else {
            throw .providerMetadataInvalid(detail: "downloaded set is empty")
        }
        return .apk(downloaded)
    }

    /// The download cap shared with the Direct provider (§5).
    static let downloadSizeLimit: Int64 = 8_589_934_592

    /// ABI fit: `nativecode` empty means universal; otherwise one must match.
    static func abiFits(_ nativecode: [String], abis: [String]) -> Bool {
        nativecode.isEmpty || !Set(nativecode).isDisjoint(with: abis)
    }

    /// The `meta.json` bookkeeping beside the cached `index.json`.
    private struct IndexMeta: Codable {
        var timestamp: Int64
        var sha256: String
    }

    /// Ensures the cached index is at `entry.timestamp`, downloading a diff
    /// or the full index as §4.5 says. Returns the index bytes (read back
    /// from the cache file so decode memory is bounded by the file).
    private func updateIndex(
        entry: FDroidEntry,
        reader: FDroidIndexReader,
        context: ProviderContext
    ) async throws(UpdateFailure) -> Data {
        let directory = try cacheDirectory(context: context)
        let indexFile = directory.appendingPathComponent("index.json")
        let metaFile = directory.appendingPathComponent("index.meta.json")
        let cached = try? JSONDecoder().decode(
            IndexMeta.self, from: Data(contentsOf: metaFile))
        if cached?.timestamp == entry.timestamp,
            FileManager.default.fileExists(atPath: indexFile.path),
            let data = try? Data(contentsOf: indexFile)
        {
            return data
        }
        log.debug("fdroid index refresh host=\(repository.host ?? "-", .public)")

        // Diff path: entry.diffs is keyed by the index timestamp it patches.
        if let cached,
            let diff = entry.diffs[String(cached.timestamp)],
            FileManager.default.fileExists(atPath: indexFile.path)
        {
            do {
                let diffFile = try await fetchFile(diff, context: context)
                let diffData = try Data(contentsOf: diffFile)
                let indexData = try Data(contentsOf: indexFile)
                let merged = try reader.merged(index: indexData, diff: diffData)
                try write(data: merged, to: indexFile)
                try write(
                    data: metaJSON(timestamp: entry.timestamp, sha256: entry.index.sha256),
                    to: metaFile)
                return merged
            } catch let failure as UpdateFailure {
                throw failure
            } catch {
                throw .providerMetadataInvalid(detail: "fdroid index merge failed")
            }
        }

        // Full index path.
        let file = try await fetchFile(entry.index, context: context)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw .providerUnreachable(reason: "cannot read the downloaded index")
        }
        guard data.count <= FDroidIndexReader.indexByteLimit else {
            throw .providerMetadataInvalid(detail: "index: over 64 MiB")
        }
        try write(data: data, to: indexFile)
        try write(
            data: metaJSON(timestamp: entry.timestamp, sha256: entry.index.sha256),
            to: metaFile)
        return data
    }

    /// Downloads `<repository>/<file.name>` to a temporary file and checks
    /// the declared size and SHA-256 (§4.5).
    private func fetchFile(_ file: FDroidEntry.File, context: ProviderContext)
        async throws(UpdateFailure) -> URL
    {
        let url = repository.appendingPathComponent(file.name)
        guard Self.isAllowed(url) else {
            throw .providerMetadataInvalid(detail: "index file URL is not allowed")
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-fdroid-\(UUID().uuidString).json")
        let response = try await context.http.download(
            url, headers: [:], into: destination, byteLimit: Self.indexByteLimit)
        guard (200...299).contains(response.status) else {
            throw DirectProvider.statusFailure(response.status, retryAfter: response.retryAfter)
        }
        guard !response.limitHit else {
            throw .providerMetadataInvalid(detail: "\(file.name): over the size limit")
        }
        guard response.bytesWritten == file.size else {
            throw .providerMetadataInvalid(detail: "\(file.name): size mismatch")
        }
        guard response.sha256?.hexValue == file.sha256.lowercased() else {
            throw .providerMetadataInvalid(detail: "\(file.name): SHA-256 mismatch")
        }
        return destination
    }

    private func cacheDirectory(context: ProviderContext) throws(UpdateFailure) -> URL {
        do {
            return try context.cache.directory(forKey: cacheKey)
        } catch {
            throw .providerUnreachable(reason: "cannot open the F-Droid cache")
        }
    }

    private func validate(_ file: FDroidEntry.File) throws(UpdateFailure) {
        guard !file.name.isEmpty, !file.name.hasPrefix("/"),
            !file.name.split(separator: "/").contains("..")
        else {
            throw .providerMetadataInvalid(detail: "entry.json: bad file name")
        }
        guard APKStoreCore.SHA256Digest(hex: file.sha256.lowercased()) != nil else {
            throw .providerMetadataInvalid(detail: "entry.json: file sha256 is not 64 hex")
        }
        guard file.size >= 0, file.size <= Self.indexByteLimit else {
            throw .providerMetadataInvalid(detail: "entry.json: file size out of range")
        }
    }

    private func write(data: Data, to url: URL) throws(UpdateFailure) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw .providerUnreachable(reason: "cannot write the F-Droid index cache")
        }
    }

    private func metaJSON(timestamp: Int64, sha256: String) -> Data {
        (try? JSONEncoder().encode(
            IndexMeta(timestamp: timestamp, sha256: sha256))) ?? Data()
    }
}
