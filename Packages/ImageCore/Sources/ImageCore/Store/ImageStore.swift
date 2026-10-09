import CryptoKit
import Darwin
import DiagnosticsCore
import Foundation

/// Where an image comes from (android-image.md §9.1). The archive case arrives with #058.
public enum ImageSource: Sendable, Equatable {
    /// A bundle directory with the files of runtime-image-manifest.md §3.1 (a development install).
    case directory(URL)
}

/// How much of an installed bundle to check (runtime-image-manifest.md §7.1).
public enum VerificationDepth: Sendable, Equatable {
    /// Steps 1–7: the signature, the schema and rules, the file set, and every size. Before every boot.
    case quick
    /// Steps 1–8: also every SHA-256 and `SHA256SUMS`. At install and in `apkrun doctor --deep`.
    case full
}

/// Owns `Images/`: verifies, installs, and selects runtime image bundles (android-image.md §9.1,
/// §10.3; runtime-image-manifest.md §7.1, §8.3).
///
/// A bundle directory is read-only once installed. `current` and `previous` are symlinks that
/// name a directory, and they move only through `setCurrent`.
public actor ImageStore {
    private let paths: APKRunPaths
    private let trust: ImageTrustStore
    private let logger: APKLogger
    private let cloneFile: @Sendable (URL, URL) throws -> Void
    /// Runs after a new image is renamed into place, before it becomes current. Tests use it to
    /// stop an install at the point where a crash would leave the image installed but not current.
    private let beforeActivation: @Sendable () throws -> Void
    private var manifestCache: [String: CachedManifest] = [:]

    /// Creates a store for the images under `paths.imagesDirectory`.
    public init(paths: APKRunPaths, trust: ImageTrustStore, diagnostics: DiagnosticsContext) {
        self.init(
            paths: paths, trust: trust, diagnostics: diagnostics, cloneFile: FileCloner.clone,
            beforeActivation: {}
        )
    }

    init(
        paths: APKRunPaths,
        trust: ImageTrustStore,
        diagnostics: DiagnosticsContext,
        cloneFile: @escaping @Sendable (URL, URL) throws -> Void,
        beforeActivation: @escaping @Sendable () throws -> Void
    ) {
        self.paths = paths
        self.trust = trust
        self.cloneFile = cloneFile
        self.beforeActivation = beforeActivation
        logger = APKLogger(category: ImageLogCategory.install, sink: diagnostics.logSink)
    }

    // MARK: Selection

    /// The current image, checked quickly. Fails with `noCurrentImage` when none is set.
    public func current() throws(ImageFailure) -> InstalledImage {
        guard let name = linkedName(paths.currentImage) else {
            throw .noCurrentImage
        }
        return try installedImage(named: name, depth: .quick)
    }

    /// The previous image, when one is kept.
    public func previous() -> InstalledImage? {
        guard let name = linkedName(paths.previousImage) else {
            return nil
        }
        return try? installedImage(named: name, depth: .quick)
    }

    /// Makes an installed image current and moves the old current image to `previous`.
    public func setCurrent(_ version: ImageVersion) throws(ImageFailure) {
        let name = version.description
        guard FileManager.default.fileExists(atPath: paths.imageDirectory(version: name).path) else {
            throw .imageNotInstalled(version: name)
        }
        _ = try installedImage(named: name, depth: .quick)
        let old = linkedName(paths.currentImage)
        guard old != name else {
            return
        }
        if let old {
            try replaceLink(paths.previousImage, with: old)
        }
        try replaceLink(paths.currentImage, with: name)
        logger.notice("Set the current image to \(name, .public)")
    }

    /// Deletes installed images other than `current`, `previous`, and `retaining`.
    public func garbageCollect(retaining extra: Set<ImageVersion> = []) throws(ImageFailure) {
        var keep = Set(extra.map(\.description))
        for link in [paths.currentImage, paths.previousImage] {
            if let name = linkedName(link) {
                keep.insert(name)
            }
        }
        for name in try directoryNames() where ImageVersion(name) != nil && !keep.contains(name) {
            try remove(paths.imageDirectory(version: name))
            manifestCache[name] = nil
            logger.notice("Removed the unused image \(name, .public)")
        }
    }

    /// Removes `Images/.installing-*` left by an interrupted install (runtime-image-manifest.md §8.3).
    /// Call it at startup, while holding the instance lock.
    public func removeOrphanedInstalls() throws(ImageFailure) {
        for name in try directoryNames() where name.hasPrefix(".installing-") {
            try remove(paths.imagesDirectory.appendingPathComponent(name, isDirectory: true))
            logger.notice("Removed an interrupted install \(name, .public)")
        }
    }

    // MARK: Verification

    /// Checks an installed image at the given depth (runtime-image-manifest.md §7.1).
    public func verify(_ image: InstalledImage, depth: VerificationDepth) throws(ImageFailure) {
        let name = image.root.lastPathComponent
        let bundle = try checkedManifest(in: image.root, cacheKey: name)
        try checkFiles(in: image.root, bundle: bundle, depth: depth)
    }

    // MARK: Install

    /// Installs a bundle directory: verifies it, clones it into `Images/.installing-<version>/`,
    /// checks the copy in full, renames it into place, and makes it current (android-image.md
    /// §10.3). An image that is already installed under this name, with the same manifest, is
    /// left as it is.
    @discardableResult
    public func install(from source: ImageSource) throws(ImageFailure) -> InstalledImage {
        guard case .directory(let directory) = source else {
            throw .manifestInvalid(path: "manifest.json", reason: "unsupported image source")
        }
        let original = try checkedManifest(in: directory, cacheKey: nil)
        try checkFiles(in: directory, bundle: original, depth: .quick)
        let version = original.manifest.imageVersion
        let name = version.description
        let target = paths.imageDirectory(version: name)

        // A candidate must be newer than every installed image, and this check runs before the
        // existing-directory branch so that a reinstall of an older image is refused too. An image
        // with the same triple and another base is not newer (§2.3), so it is refused as well.
        // The installed images are the directories under Images/ and the target of `current`,
        // which covers an interrupted activation (IR-347, IR-359).
        let blocking = try installedVersions().filter { $0 != version && !($0 < version) }
        if let highest = blocking.max(by: Self.isBefore) {
            throw .downgradeRejected(from: highest.description, to: name)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            let installed = try checkedManifest(in: target, cacheKey: nil)
            guard installed.manifestBytes == original.manifestBytes else {
                throw .unexpectedFile(file: "manifest.json")
            }
            try checkFiles(in: target, bundle: installed, depth: .full)
            try setCurrent(version)
            return try installedImage(named: name, depth: .quick)
        }

        let staging = paths.imageInstallStagingDirectory(name: name)
        try remove(staging)
        try makeDirectory(staging)
        do {
            try copyFiles(of: original, from: directory, to: staging)
            let copy = try checkedManifest(in: staging, cacheKey: nil)
            // The source may have changed after it was read. The clone is then a different
            // image, and it must not be installed under the name of the first one.
            guard copy.manifestBytes == original.manifestBytes else {
                throw ImageFailure.unexpectedFile(file: "manifest.json")
            }
            try checkFiles(in: staging, bundle: copy, depth: .full)
            // Nothing under Images/<version>/ changes after installation (filesystem-layout.md §1).
            try setWritable(staging, false)
        } catch let failure as ImageFailure {
            try? remove(staging)
            throw failure
        } catch {
            try? remove(staging)
            throw storageFailure(error)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: target)
        } catch {
            try? remove(staging)
            throw storageFailure(error)
        }
        logger.notice("Installed the image \(name, .public) from a directory")
        do {
            try beforeActivation()
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw storageFailure(error)
        }
        try setCurrent(version)
        return try installedImage(named: name, depth: .quick)
    }

    // MARK: Helpers

    /// Every installed image version: the version-named directories under `Images/`, and the
    /// target of `current` even when that directory is missing.
    private func installedVersions() throws(ImageFailure) -> [ImageVersion] {
        var versions = try directoryNames().compactMap(ImageVersion.init)
        if let name = linkedName(paths.currentImage), let current = ImageVersion(name),
            !versions.contains(current)
        {
            versions.append(current)
        }
        return versions
    }

    /// Orders versions by triple, then by base, so that a same-triple pair has an order too.
    private static func isBefore(_ lhs: ImageVersion, _ rhs: ImageVersion) -> Bool {
        lhs < rhs || (lhs.shortForm == rhs.shortForm && lhs.base < rhs.base)
    }

    /// The parsed manifest and the exact bytes that the signature covers.
    private struct CheckedBundle {
        let manifest: RuntimeImageManifest
        let manifestBytes: Data
        let signatureBytes: Data
    }

    private struct CachedManifest {
        let identity: [String]
        let bundle: CheckedBundle
    }

    private func installedImage(named name: String, depth: VerificationDepth) throws(ImageFailure) -> InstalledImage {
        let directory = paths.imageDirectory(version: name)
        let bundle = try checkedManifest(in: directory, cacheKey: name)
        try checkFiles(in: directory, bundle: bundle, depth: depth)
        return InstalledImage(version: bundle.manifest.imageVersion, root: directory, manifest: bundle.manifest)
    }

    /// Steps 1–6 of §7.1, with the cache of quick verification keyed by the identity of
    /// `manifest.json` and `manifest.sig`. Install passes `nil` for the key and never reads the cache.
    private func checkedManifest(in directory: URL, cacheKey: String?) throws(ImageFailure) -> CheckedBundle {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let signatureURL = directory.appendingPathComponent("manifest.sig")
        let identity = try identityOf(manifestURL) + identityOf(signatureURL)
        if let cacheKey, let cached = manifestCache[cacheKey], cached.identity == identity {
            return cached.bundle
        }
        let manifestBytes = try readFile(manifestURL, limit: ManifestLimits.manifestBytes, name: "manifest.json")
        let signatureBytes = try readFile(signatureURL, limit: ManifestLimits.signatureBytes, name: "manifest.sig")
        try ImageSignature.verify(message: manifestBytes, signatureFile: signatureBytes, trust: trust)
        let manifest = try RuntimeImageManifest.load(manifestBytes)
        if let cacheKey, manifest.imageVersion.description != cacheKey {
            throw .manifestInvalid(path: "imageVersion", reason: "does not match the directory name")
        }
        let bundle = CheckedBundle(manifest: manifest, manifestBytes: manifestBytes, signatureBytes: signatureBytes)
        if let cacheKey {
            manifestCache[cacheKey] = CachedManifest(identity: identity, bundle: bundle)
        }
        return bundle
    }

    /// Step 7 (the file set and every size), and step 8 at `.full` (every hash and `SHA256SUMS`).
    private func checkFiles(
        in directory: URL, bundle: CheckedBundle, depth: VerificationDepth
    ) throws(ImageFailure) {
        let metadata = ["manifest.json", "manifest.sig", "SHA256SUMS"]
        let expected = Set(metadata + bundle.manifest.files.map(\.path))
        let found = try regularFiles(in: directory, expected: expected)
        if let extra = found.subtracting(expected).sorted().first {
            throw .unexpectedFile(file: extra)
        }
        if let missing = expected.subtracting(found).sorted().first {
            throw .missingFile(file: missing)
        }
        for entry in bundle.manifest.files {
            let size = try fileSize(directory.appendingPathComponent(entry.path), name: entry.path)
            guard size == entry.size else {
                throw .hashMismatch(file: entry.path)
            }
        }
        guard depth == .full else {
            return
        }
        for entry in bundle.manifest.files {
            let digest = try sha256(of: directory.appendingPathComponent(entry.path), name: entry.path)
            guard digest == entry.sha256 else {
                throw .hashMismatch(file: entry.path)
            }
        }
        let sums = try readFile(
            directory.appendingPathComponent("SHA256SUMS"), limit: 1024 * 1024, name: "SHA256SUMS"
        )
        guard sums == checksumText(bundle.manifest.files) else {
            throw .manifestInvalid(path: "SHA256SUMS", reason: "does not list the files of the manifest")
        }
    }

    private func checksumText(_ files: [RuntimeImageManifest.FileEntry]) -> Data {
        Data(files.map { "\($0.sha256)  \($0.path)\n" }.joined().utf8)
    }

    /// Clones every file of the bundle into `staging`, creating the directories it needs.
    private func copyFiles(of bundle: CheckedBundle, from source: URL, to staging: URL) throws(ImageFailure) {
        let names = ["manifest.json", "manifest.sig", "SHA256SUMS"] + bundle.manifest.files.map(\.path)
        for name in names {
            let destination = staging.appendingPathComponent(name)
            try makeDirectory(destination.deletingLastPathComponent())
            do {
                try cloneFile(source.appendingPathComponent(name), destination)
            } catch let failure as ImageFailure {
                throw failure
            } catch {
                throw storageFailure(error)
            }
        }
    }

    /// The regular files under `directory`, as relative paths. A symlink, a special file, or a
    /// directory that holds nothing the manifest lists is reported as an unexpected file.
    private func regularFiles(in directory: URL, expected: Set<String>) throws(ImageFailure) -> Set<String> {
        let root = directory.standardizedFileURL.path
        guard
            let walker = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
        else {
            throw .missingFile(file: "manifest.json")
        }
        var found: Set<String> = []
        var directories: Set<String> = []
        for case let url as URL in walker {
            let relative = String(url.standardizedFileURL.path.dropFirst(root.count + 1))
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
            if values?.isSymbolicLink == true {
                throw .unexpectedFile(file: relative)
            } else if values?.isDirectory == true {
                directories.insert(relative)
            } else if values?.isRegularFile == true {
                found.insert(relative)
            } else {
                throw .unexpectedFile(file: relative)
            }
        }
        for relative in directories where !expected.contains(where: { $0.hasPrefix(relative + "/") }) {
            throw .unexpectedFile(file: relative)
        }
        return found
    }

    /// The `stat` of a regular file, taken without following a symbolic link. A missing file is
    /// `missingFile`. A link, or any other entry that is not a regular file, is `unexpectedFile`:
    /// the bundle may hold nothing but its listed regular files (§7.1 step 7, AGENTS §9).
    private func regularFileStatus(_ url: URL, name: String) throws(ImageFailure) -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw .missingFile(file: name)
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw .unexpectedFile(file: name)
        }
        return status
    }

    /// Opens a regular file without following a link at its last component.
    private func openRegularFile(_ url: URL, name: String) throws(ImageFailure) -> FileHandle {
        _ = try regularFileStatus(url, name: name)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw .unexpectedFile(file: name)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func fileSize(_ url: URL, name: String) throws(ImageFailure) -> UInt64 {
        UInt64(try regularFileStatus(url, name: name).st_size)
    }

    private func identityOf(_ url: URL) throws(ImageFailure) -> [String] {
        let status = try regularFileStatus(url, name: url.lastPathComponent)
        return [
            "\(status.st_ino)",
            "\(status.st_size)",
            "\(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)",
        ]
    }

    private func readFile(_ url: URL, limit: Int, name: String) throws(ImageFailure) -> Data {
        let size = try fileSize(url, name: name)
        guard size <= limit else {
            throw .manifestInvalid(path: name, reason: "larger than the limit")
        }
        let handle = try openRegularFile(url, name: name)
        defer { try? handle.close() }
        let data: Data
        do {
            // One byte past the limit, so that a file that grew since it was measured is caught.
            data = try handle.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw storageFailure(error)
        }
        guard data.count <= limit else {
            throw .manifestInvalid(path: name, reason: "larger than the limit")
        }
        return data
    }

    private func sha256(of url: URL, name: String) throws(ImageFailure) -> String {
        let handle = try openRegularFile(url, name: name)
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            throw storageFailure(error)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func linkedName(_ link: URL) -> String? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return nil
        }
        return URL(fileURLWithPath: target).lastPathComponent
    }

    /// Points `link` at `name` in one rename, so a reader sees either the old or the new target.
    private func replaceLink(_ link: URL, with name: String) throws(ImageFailure) {
        let temporary = link.deletingLastPathComponent()
            .appendingPathComponent(".\(link.lastPathComponent)-\(UUID().uuidString)")
        do {
            try FileManager.default.createSymbolicLink(atPath: temporary.path, withDestinationPath: name)
        } catch {
            throw storageFailure(error)
        }
        guard rename(temporary.path, link.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw .cloneFailed(underlying: UnderlyingError(domain: "NSPOSIXErrorDomain", code: Int(code)))
        }
    }

    private func directoryNames() throws(ImageFailure) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: paths.imagesDirectory.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return []
        } catch {
            throw storageFailure(error)
        }
    }

    private func makeDirectory(_ url: URL) throws(ImageFailure) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw storageFailure(error)
        }
    }

    private func remove(_ url: URL) throws(ImageFailure) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        // An installed image is read-only, so its owner write bits come back before it is removed.
        try? setWritable(url, true)
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw storageFailure(error)
        }
    }

    /// Clears the write bits of `root` and of everything under it, or restores the owner's write bit.
    /// Read and search bits stay, so the tree can still be verified and listed. Symbolic links are
    /// left alone, although the file check has already refused any.
    private func setWritable(_ root: URL, _ writable: Bool) throws(ImageFailure) {
        var urls = [root]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) {
            for case let url as URL in walker {
                urls.append(url)
            }
        }
        for url in urls {
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw .missingFile(file: url.lastPathComponent)
            }
            if status.st_mode & S_IFMT == S_IFLNK {
                continue
            }
            let mode =
                writable
                ? status.st_mode | S_IWUSR
                : status.st_mode & ~(S_IWUSR | S_IWGRP | S_IWOTH)
            guard chmod(url.path, mode) == 0 else {
                throw .cloneFailed(underlying: UnderlyingError(domain: "NSPOSIXErrorDomain", code: Int(errno)))
            }
        }
    }

    private func storageFailure(_ error: Error) -> ImageFailure {
        let nsError = error as NSError
        return .cloneFailed(underlying: UnderlyingError(domain: nsError.domain, code: nsError.code))
    }
}

/// `clonefile(2)`: a copy-on-write copy, which keeps the holes of sparse files (§10.3).
enum FileCloner {
    static func clone(_ source: URL, _ destination: URL) throws {
        guard clonefile(source.path, destination.path, 0) == 0 else {
            let code = errno
            switch code {
            case EXDEV, ENOTSUP, EOPNOTSUPP:
                throw ImageFailure.cloneUnsupported(volume: destination.deletingLastPathComponent().path)
            default:
                throw ImageFailure.cloneFailed(
                    underlying: UnderlyingError(domain: "NSPOSIXErrorDomain", code: Int(code)))
            }
        }
    }
}
