import APKStoreCore
import Foundation

/// Parses `ProviderSpec.spec` strings into provider configurations and creates
/// providers from stored references (update-system.md §4, runtime-api.md §9.2).
public enum ProviderRegistry {
    /// The local provider is a development feature; it exists only while
    /// `developer.enabled` is on (configuration.md §2.5).
    /// - Throws: `providerNotConfigured` when the type is not usable here,
    ///   `providerMetadataInvalid` when the spec is malformed.
    public static func parse(
        _ spec: String,
        bookmark: Data? = nil,
        developerModeEnabled: Bool
    ) throws(UpdateFailure) -> UpdateProviderRef {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let type = ProviderType(rawValue: String(parts[0])) else {
            throw UpdateFailure.providerMetadataInvalid(detail: "unknown provider spec")
        }
        let body = String(parts[1])
        switch type {
        case .local:
            guard developerModeEnabled else {
                throw UpdateFailure.providerNotConfigured
            }
            guard !body.isEmpty else {
                throw UpdateFailure.providerMetadataInvalid(detail: "local provider needs a path")
            }
            guard let bookmark else {
                throw UpdateFailure.providerMetadataInvalid(
                    detail: "local provider needs a security-scoped bookmark")
            }
            return UpdateProviderRef(
                type: .local,
                configuration: .local(path: body, bookmark: bookmark.base64EncodedString()))
        case .direct:
            return UpdateProviderRef(
                type: .direct,
                configuration: .direct(url: try Self.directURL(body)))
        case .fdroid, .github:
            // Parsed in the provider's own task (#52, #53).
            throw UpdateFailure.providerNotConfigured
        }
    }

    /// A direct manifest URL: HTTPS at most 2048 characters with no user
    /// info, or a loopback HTTP URL in debug builds for the local test
    /// service (direct-provider-manifest.md §8).
    static func directURL(_ spec: String) throws(UpdateFailure) -> String {
        guard spec.utf8.count <= 2048 else {
            throw UpdateFailure.providerMetadataInvalid(
                detail: "direct provider URL is over 2048 characters")
        }
        guard let url = URL(string: spec), let scheme = url.scheme?.lowercased(),
            url.host != nil
        else {
            throw UpdateFailure.providerMetadataInvalid(detail: "direct provider needs a URL")
        }
        guard url.user == nil, url.password == nil else {
            throw UpdateFailure.providerMetadataInvalid(
                detail: "direct provider URL must not carry user info")
        }
        if scheme == "https" { return spec }
        #if DEBUG
            if scheme == "http",
                let host = url.host?.lowercased(),
                host == "127.0.0.1" || host == "localhost"
            {
                return spec
            }
        #endif
        throw UpdateFailure.providerMetadataInvalid(detail: "direct provider URL must be https")
    }

    /// Creates the provider implementation for a stored configuration.
    public static func provider(
        for ref: UpdateProviderRef,
        developerModeEnabled: Bool
    ) throws(UpdateFailure) -> any UpdateProvider {
        switch ref.configuration {
        case .local(let path, let bookmark):
            guard developerModeEnabled else {
                throw UpdateFailure.providerNotConfigured
            }
            guard let data = Data(base64Encoded: bookmark),
                let root = Self.resolveBookmark(data)
            else {
                throw UpdateFailure.providerUnreachable(
                    reason: "local provider bookmark cannot be resolved")
            }
            return LocalProvider(ref: ref, root: root, displayPath: path)
        case .direct:
            return try DirectProvider(ref: ref)
        case .fdroid, .github:
            // F-Droid (#52), GitHub (#53).
            throw UpdateFailure.providerNotConfigured
        }
    }

    /// Resolves a security-scoped bookmark to a file URL.
    static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
        else { return nil }
        return url
    }
}

/// The development provider that reads `<root>/<packageId>/<versionCode>/`
/// directories on this Mac (update-system.md §4.3). No network, no hashes.
public struct LocalProvider: UpdateProvider {
    /// The provider identity stored on the package record.
    public var ref: UpdateProviderRef
    /// The resolved repository root.
    let root: URL
    /// The path shown to the user (the spec form, not the resolved URL).
    let displayPath: String

    /// Creates a local provider over a resolved root directory.
    public init(ref: UpdateProviderRef, root: URL, displayPath: String) {
        self.ref = ref
        self.root = root
        self.displayPath = displayPath
    }

    /// Returns the newest version directory above the installed version, or nil.
    public func check(
        _ package: InstalledPackage,
        context _: ProviderContext
    ) async throws(UpdateFailure) -> UpdateCandidate? {
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        let packageDirectory = root.appendingPathComponent(package.id.rawValue, isDirectory: true)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: packageDirectory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            // The repository simply does not carry this package.
            return nil
        }
        guard
            let entries = try? FileManager.default.contentsOfDirectory(atPath: packageDirectory.path)
        else {
            throw UpdateFailure.providerUnreachable(
                reason: "local repository directory cannot be read")
        }

        // The highest numeric directory above the installed versionCode.
        // Directory "0" is never a candidate.
        let candidates = entries.compactMap { name -> (VersionCode, String)? in
            guard name.first?.isNumber == true, let code = VersionCode(name), code > 0 else {
                return nil
            }
            var entryIsDirectory = ObjCBool(false)
            guard
                FileManager.default.fileExists(
                    atPath: packageDirectory.appendingPathComponent(name).path,
                    isDirectory: &entryIsDirectory
                ), entryIsDirectory.boolValue
            else {
                return nil
            }
            return (code, name)
        }
        guard
            let (versionCode, directoryName) =
                candidates
                .filter({ $0.0 > package.versionCode })
                .max(by: { $0.0 < $1.0 })
        else {
            return nil
        }

        let versionDirectory = packageDirectory.appendingPathComponent(directoryName, isDirectory: true)
        let attributes = try? FileManager.default.attributesOfItem(atPath: versionDirectory.path)
        let modified = attributes?[.modificationDate] as? Date
        let cursor = ProviderCursor(
            type: .local,
            value: "\(directoryName)@\(Int(modified?.timeIntervalSince1970 ?? 0))")
        if package.lastCursor == cursor {
            return nil
        }

        let artifacts = try Self.artifacts(in: versionDirectory)
        return UpdateCandidate(
            packageID: package.id,
            provider: ref,
            declaredVersionCode: versionCode,
            artifacts: artifacts,
            cursor: cursor
        )
    }

    /// One version directory holds `app.apk`, `base.apk` plus `split_*.apk`
    /// files, or a single `.apks` container.
    private static func artifacts(
        in directory: URL
    ) throws(UpdateFailure) -> [RemoteArtifact] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            throw UpdateFailure.providerUnreachable(
                reason: "local version directory cannot be read")
        }
        let visible = names.filter { !$0.hasPrefix(".") }
        let apks = visible.filter { $0.hasSuffix(".apk") }
        let containers = visible.filter { $0.hasSuffix(".apks") }

        func artifact(_ name: String, kind: RemoteArtifactKind) -> RemoteArtifact {
            let url = directory.appendingPathComponent(name)
            let size =
                (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            return RemoteArtifact(url: url, kind: kind, size: size)
        }

        if containers.count == 1, apks.isEmpty, visible.count == 1 {
            return [artifact(containers[0], kind: .container)]
        }
        if apks == ["app.apk"], visible.count == 1 {
            return [artifact("app.apk", kind: .apk)]
        }
        let splits = apks.filter { $0 != "base.apk" }
        if apks.contains("base.apk"),
            splits.allSatisfy({ $0.hasPrefix("split_") }),
            apks.count == visible.count
        {
            var result = [artifact("base.apk", kind: .apk)]
            for split in splits.sorted() {
                let name = String(split.dropFirst("split_".count).dropLast(".apk".count))
                result.append(artifact(split, kind: .split(name)))
            }
            return result
        }
        throw UpdateFailure.providerMetadataInvalid(
            detail: "version directory holds no recognized APK layout")
    }

    /// Copies the candidate's APK set into the destination directory.
    public func download(
        _ candidate: UpdateCandidate,
        to destination: DownloadDestination,
        context _: ProviderContext,
        progress: @Sendable (DownloadProgress) -> Void
    ) async throws(UpdateFailure) -> PackageArtifact {
        let accessed = root.startAccessingSecurityScopedResource()
        defer { if accessed { root.stopAccessingSecurityScopedResource() } }

        let total = candidate.artifacts.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var written: Int64 = 0
        var copied: [RemoteArtifact] = []
        for (index, artifact) in candidate.artifacts.enumerated() {
            let target = destination.directory
                .appendingPathComponent(
                    artifact.storedFileName(index: index, in: candidate.artifacts))
            do {
                try FileManager.default.removeItemIfPresent(at: target)
                // clonefile where the filesystem supports it, else a copy.
                if clonefile(artifact.url.path, target.path, 0) != 0 {
                    try FileManager.default.copyItem(at: artifact.url, to: target)
                }
            } catch {
                throw UpdateFailure.downloadFailed(reason: error.localizedDescription)
            }
            written +=
                artifact.size
                ?? Int64(
                    (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            progress(DownloadProgress(bytesWritten: written, bytesTotal: total > 0 ? total : nil))
            var copy = artifact
            copy.url = target
            copied.append(copy)
        }

        if copied.count == 1, copied[0].kind == .container {
            return .container(copied[0].url)
        }
        guard
            let base = copied.first(where: { $0.kind == .apk })
        else {
            throw UpdateFailure.providerMetadataInvalid(detail: "downloaded set has no base APK")
        }
        let splits = copied.filter { $0.url != base.url }.map(\.url)
        if splits.isEmpty {
            return .apk(base.url)
        }
        return .splitSet(base: base.url, splits: splits)
    }
}

extension FileManager {
    /// Removes a file that may not exist.
    func removeItemIfPresent(at url: URL) throws {
        if fileExists(atPath: url.path) {
            try removeItem(at: url)
        }
    }
}
