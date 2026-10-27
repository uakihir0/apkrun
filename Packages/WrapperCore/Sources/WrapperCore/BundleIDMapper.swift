import CryptoKit
import Foundation
import RuntimeAPI

/// Maps an Android package identifier to its stable macOS bundle identifier.
public enum BundleIDMapper {
    /// Returns the deterministic bundle identifier for a validated Android package identifier.
    public static func map(_ packageID: RuntimePackageID) -> String {
        let rawValue = packageID.rawValue
        var mapped = rawValue.replacingOccurrences(of: "_", with: "-")

        if rawValue.contains(where: \.isUppercase) {
            let digest = SHA256.hash(data: Data(rawValue.utf8))
            let suffix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
            mapped += "-h\(suffix)"
        }

        return "io.apkrun.android.\(mapped)"
    }
}
