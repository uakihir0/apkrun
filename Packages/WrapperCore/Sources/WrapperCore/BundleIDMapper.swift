import CryptoKit
import Foundation
import RuntimeAPI

/// The deterministic mapping between an Android package ID and a Mac bundle ID
/// (wrapper.md §4.1, FR-WRP-05).
public enum BundleIDMapper {
    /// The permanent bundle ID prefix (OQ-01).
    public static let prefix = "io.apkrun.android."

    /// Maps a package ID to its bundle ID. The result depends only on the input.
    ///
    /// Every `_` becomes `-` (reversible because Android IDs never contain `-`),
    /// and an ID with an uppercase letter gains a `-h<8 hex>` content suffix so
    /// that two packages that differ only in case stay distinct on macOS.
    public static func map(_ packageID: String) -> String {
        var mapped = packageID.replacingOccurrences(of: "_", with: "-")
        if packageID.contains(where: { $0.isUppercase }) {
            let digest = SHA256.hash(data: Data(packageID.utf8))
            let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            mapped += "-h" + suffix
        }
        return prefix + mapped
    }

    /// Maps a package ID to its bundle ID.
    public static func map(_ packageID: RuntimePackageID) -> String {
        map(packageID.rawValue)
    }
}
