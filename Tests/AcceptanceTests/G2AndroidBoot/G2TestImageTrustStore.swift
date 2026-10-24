import Foundation
import ImageCore

/// The composed-image signer trusted by the G2 test process.
enum G2TestImageTrustStore {
    enum Failure: Error, CustomStringConvertible {
        case bundleManifestInvalid(URL)
        case fixtureKeyMissing

        var description: String {
            switch self {
            case .bundleManifestInvalid(let path):
                "The selected G2 image manifest is missing or invalid at \(path)."
            case .fixtureKeyMissing:
                "The G2 composed-image test signer is missing from the AcceptanceTests bundle."
            }
        }
    }

    static func make(
        for bundle: URL,
        standard: ImageTrustStore = .standard()
    ) throws -> ImageTrustStore {
        let manifestURL = bundle.appendingPathComponent("manifest.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw Failure.bundleManifestInvalid(manifestURL)
        }
        let provenance = manifest["provenance"] as? [String: Any]
        guard manifest["kind"] as? String == "apkrun",
            provenance?["composition"] is [String: Any]
        else {
            return standard
        }

        guard
            let keyURL = Bundle(for: G2TestTrustBundleMarker.self)
                .url(forResource: "test-image-ed25519", withExtension: "pub"),
            let text = try? String(contentsOf: keyURL, encoding: .utf8),
            let publicKey = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            publicKey.count == 32
        else {
            throw Failure.fixtureKeyMissing
        }

        let fixtureKey = ImageTrustStore.Key(publicKey: publicKey)
        guard standard.key(for: fixtureKey.keyID) == nil else {
            return standard
        }
        return ImageTrustStore(keys: standard.keys + [fixtureKey])
    }
}

private final class G2TestTrustBundleMarker: NSObject {}
