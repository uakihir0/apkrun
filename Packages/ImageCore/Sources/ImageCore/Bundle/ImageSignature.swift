import CryptoKit
import Foundation

/// `manifest.sig`: an Ed25519 signature over the exact bytes of `manifest.json`
/// (runtime-image-manifest.md §6.1). The reader matches `apkrun_image.sign`, and both sides
/// check the vectors in `Images/tools/tests/fixtures/signing/image-signature-vectors.json`.
public enum ImageSignature {
    /// The first line of every signature file.
    public static let tag = "apkrun-signature-v1"

    /// A parsed signature file.
    public struct Parsed: Equatable, Sendable {
        /// The key ID that names the signing key.
        public let keyID: String
        /// The 64-byte Ed25519 signature.
        public let signature: Data
    }

    /// The key ID of a raw 32-byte Ed25519 public key: the first 8 bytes of its SHA-256, in
    /// lowercase hex.
    public static func keyID(of publicKey: Data) -> String {
        SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Parses `manifest.sig` strictly: four LF-terminated ASCII lines (§6.1). Anything else
    /// is `manifestInvalid`.
    public static func parse(_ data: Data) throws(ImageFailure) -> Parsed {
        func invalid(_ reason: String) -> ImageFailure {
            .manifestInvalid(path: "manifest.sig", reason: reason)
        }
        guard data.count <= ManifestLimits.signatureBytes else {
            throw invalid("larger than 4 KiB")
        }
        guard data.allSatisfy({ $0 < 0x80 }), !data.contains(0x0D) else {
            throw invalid("must be ASCII with LF line ends")
        }
        // Split on the LF byte: a Swift String would treat CR LF as one character.
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard lines.count == 5, lines[4].isEmpty else {
            throw invalid("must be four LF-terminated lines")
        }
        let text = lines.prefix(4).map { String(decoding: $0, as: UTF8.self) }
        guard text[0] == tag else {
            throw invalid("unknown format tag")
        }
        guard text[1].hasPrefix("key-id: ") else {
            throw invalid("no key-id line")
        }
        let keyID = String(text[1].dropFirst("key-id: ".count))
        guard keyID.count == 16, keyID.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw invalid("key ID is not 16 lowercase hex digits")
        }
        guard text[2] == "algorithm: ed25519" else {
            throw invalid("algorithm is not ed25519")
        }
        guard text[3].hasPrefix("signature: ") else {
            throw invalid("no signature line")
        }
        guard
            let signature = Data(base64Encoded: String(text[3].dropFirst("signature: ".count))),
            signature.count == 64
        else {
            throw invalid("signature is not 64 bytes of base64")
        }
        return Parsed(keyID: keyID, signature: signature)
    }

    /// Checks `signatureFile` over `message`: parse, then the trust list, then the signature
    /// (§7.1 steps 1–3). An unknown key is `untrustedKey`; a bad signature is `signatureInvalid`.
    @discardableResult
    public static func verify(
        message: Data, signatureFile: Data, trust: ImageTrustStore
    ) throws(ImageFailure) -> Parsed {
        let parsed = try parse(signatureFile)
        guard let key = trust.key(for: parsed.keyID) else {
            throw .untrustedKey(keyID: parsed.keyID)
        }
        guard
            let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey),
            publicKey.isValidSignature(parsed.signature, for: message)
        else {
            throw .signatureInvalid(keyID: parsed.keyID)
        }
        return parsed
    }
}
