import Foundation
import ZIPFoundation

/// The container format detected from a file's content (package-store.md §4.2).
enum DetectedContainer: Sendable, Equatable {
    /// A plain APK (or one of several files dropped together).
    case apk
    /// A bundletool `.apks` archive.
    case apks
    /// An APKPure `.xapk` archive; carries the extracted split file list.
    case xapk(splitFiles: [String])
    /// An APKMirror `.apkm` archive.
    case apkm
    /// A `.zip` whose entries are all APKs.
    case zipOfAPKs
}

/// Streams container entries into `incoming/<ticket>/` under the limits of package-store.md §4.2.
///
/// Detection uses content, never the extension alone. Extraction never uses the archive's
/// extract-to-directory helpers: every entry is checked and streamed with a fixed name.
struct ContainerReader: Sendable {
    /// The limits of package-store.md §4.2.
    static let maxEntries = 512
    static let maxAPKs = 256
    static let maxFileBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let maxTotalBytes: Int64 = 8 * 1_024 * 1_024 * 1_024
    static let maxCompressionRatio: Double = 100

    /// Detects the container by content (package-store.md §4.2).
    func detect(at url: URL) throws(StoreFailure) -> DetectedContainer {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw .unreadableArchive(detail: "the file cannot be opened")
        }
        // Read through the file-backed archive, never `Archive(data:)`: the memory file
        // traps when a corrupted central directory seeks past the end of the buffer.
        guard let archive = try? Archive(url: url, accessMode: .read) else {
            // APKMirror's encrypted export is not a readable ZIP. The extension only decides which
            // refusal the user sees; any other unreadable file is `.unreadableArchive`.
            if url.pathExtension.lowercased() == "apkm" {
                throw StoreFailure.unsupportedContainer(.encryptedAPKM)
            }
            throw .unreadableArchive(detail: "not a ZIP archive")
        }

        var names: [String] = []
        var entryCount = 0
        for entry in archive {
            entryCount += 1
            guard entryCount <= Self.maxEntries else {
                throw StoreFailure.archiveLimitExceeded(.entryCount)
            }
            if entry.type == .symlink {
                throw StoreFailure.archiveLimitExceeded(.unsafeName)
            }
            let name = entry.path
            guard !name.hasPrefix("/"),
                !name.components(separatedBy: "/").contains("..")
            else {
                throw StoreFailure.archiveLimitExceeded(.unsafeName)
            }
            names.append(name)
        }

        if names.contains(where: { $0.lowercased().hasSuffix(".obb") }) {
            throw StoreFailure.expansionFilesNotSupported
        }
        if names.contains("BundleConfig.pb") || names.contains("BundleConfig.json") {
            throw StoreFailure.unsupportedContainer(.appBundle)
        }
        if names.contains("toc.pb"), names.contains(where: { $0.hasPrefix("splits/") && $0.hasSuffix(".apk") }) {
            return .apks
        }
        if let manifestData = readEntryData(archive: archive, name: "manifest.json"),
            let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
            manifest["xapk_version"] != nil
        {
            if Self.xapkHasExpansions(manifest: manifest, entryNames: names) {
                throw StoreFailure.expansionFilesNotSupported
            }
            let splitFiles =
                (manifest["split_apks"] as? [[String: Any]])?
                .compactMap { $0["file"] as? String } ?? []
            return .xapk(splitFiles: splitFiles)
        }
        if let infoData = readEntryData(archive: archive, name: "info.json"),
            let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any],
            info["apkm_version"] != nil
        {
            return .apkm
        }
        if names.contains("AndroidManifest.xml") {
            return .apk
        }
        if !names.isEmpty, names.allSatisfy({ $0.hasSuffix(".apk") || $0.hasSuffix("/") }) {
            return .zipOfAPKs
        }
        throw .unsupportedContainer(.unknown)
    }

    /// Extracts the APKs of a detected container into `destination`, returning the written files.
    ///
    /// Extracted files get fixed names (`split01.apk`, …): entry names never become paths.
    func extract(
        _ container: DetectedContainer,
        from url: URL,
        into destination: URL
    ) throws(StoreFailure) -> [URL] {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            throw .io
        }
        if container == .apk {
            let target = destination.appendingPathComponent("split01.apk")
            do {
                try FileManager.default.copyItem(at: url, to: target)
            } catch {
                throw .io
            }
            return [target]
        }

        guard let archive = try? Archive(url: url, accessMode: .read)
        else {
            throw .unreadableArchive(detail: "not a ZIP archive")
        }

        let wanted: (Entry) -> Bool
        switch container {
        case .apks:
            wanted = {
                let name = $0.path
                return $0.type == .file && name.hasPrefix("splits/") && name.hasSuffix(".apk")
            }
        case .xapk(let splitFiles):
            let wantedNames = Set(splitFiles)
            wanted = {
                $0.type == .file && $0.path.hasSuffix(".apk")
                    && (wantedNames.isEmpty || wantedNames.contains($0.path))
            }
        case .apkm, .zipOfAPKs:
            wanted = { $0.type == .file && $0.path.hasSuffix(".apk") }
        case .apk:
            wanted = { _ in false }
        }

        var written: [URL] = []
        var total: Int64 = 0
        for entry in archive where wanted(entry) {
            guard written.count + 1 <= Self.maxAPKs else {
                throw StoreFailure.archiveLimitExceeded(.apkCount)
            }
            guard entry.uncompressedSize <= Self.maxFileBytes else {
                throw StoreFailure.archiveLimitExceeded(.fileSize)
            }
            total += Int64(entry.uncompressedSize)
            guard total <= Self.maxTotalBytes else {
                throw StoreFailure.archiveLimitExceeded(.totalSize)
            }
            if entry.compressedSize > 0,
                Double(entry.uncompressedSize) / Double(entry.compressedSize) > Self.maxCompressionRatio
            {
                throw StoreFailure.archiveLimitExceeded(.compressionRatio)
            }
            let target = destination.appendingPathComponent(
                String(format: "split%02d.apk", written.count + 1))
            do {
                _ = try archive.extract(entry, to: target)
            } catch {
                throw .io
            }
            written.append(target)
        }
        guard !written.isEmpty else { throw .unsupportedContainer(.unknown) }
        return written
    }

    /// Detects and extracts in one call for the import pipeline.
    func extractAPKs(from url: URL, into destination: URL) throws(StoreFailure) -> [URL] {
        let container = try detect(at: url)
        return try extract(container, from: url, into: destination)
    }

    private func readEntryData(archive: Archive, name: String) -> Data? {
        guard let entry = archive[name], entry.uncompressedSize <= 1_048_576 else { return nil }
        var buffer = Data()
        return (try? archive.extract(entry) { chunk in buffer.append(chunk) }).map { _ in buffer }
    }

    private static func xapkHasExpansions(manifest: [String: Any], entryNames: [String]) -> Bool {
        if let expansions = manifest["expansions"] as? [[String: Any]], !expansions.isEmpty {
            return true
        }
        if let expansions = manifest["expansions"] as? [String], !expansions.isEmpty {
            return true
        }
        return entryNames.contains { $0.lowercased().hasSuffix(".obb") }
    }
}
