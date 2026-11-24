import CryptoKit
import Foundation

/// One entry of the wrapper hash list: a bundle-relative path and the
/// SHA-256 of that file's contents.
public struct WrapperFileHash: Sendable, Equatable {
    /// The path inside the bundle, such as `Contents/Resources/wrapper.json`.
    public let path: String
    /// The lowercase hex SHA-256 of the file's bytes.
    public let sha256: String

    /// Creates one hash-list entry.
    public init(path: String, sha256: String) {
        self.path = path
        self.sha256 = sha256
    }
}

/// The file-content fingerprint of a wrapper bundle (wrapper.md §9.1, the
/// G9 check of #50): every regular file under the `.app`, sorted by its
/// relative path. Contents only — file names, extended attributes, and
/// metadata never count, so Spotlight tagging or a Finder touch does not
/// change the list.
public enum WrapperFileHashes {
    /// Returns the sorted hash list of every regular file in `bundleURL`.
    /// The launcher binary, `Info.plist`, `wrapper.json`, the icon, and the
    /// `_CodeSignature` payload are ordinary regular files and appear like
    /// any other entry.
    public static func compute(bundleURL: URL) throws -> [WrapperFileHash] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: bundleURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            )
        else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var hashes: [WrapperFileHash] = []
        let root = bundleURL.standardizedFileURL.path + "/"
        while let file = enumerator.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { continue }
            let standard = file.standardizedFileURL.path
            guard standard.hasPrefix(root) else { continue }
            let relative = String(standard.dropFirst(root.count))
            let digest = SHA256.hash(data: try Data(contentsOf: file))
                .map { String(format: "%02x", $0) }.joined()
            hashes.append(WrapperFileHash(path: relative, sha256: digest))
        }
        return hashes.sorted { $0.path < $1.path }
    }
}
