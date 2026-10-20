import CryptoKit
import Foundation

/// A stable digest used to verify that an operation status belongs to the original request.
public enum RuntimeOperationRequestFingerprint {
    /// Hashes an already encoded request payload using SHA-256.
    public static func make(from payload: Data) -> String {
        let digest = SHA256.hash(data: payload)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    /// Encodes a request with sorted keys, then returns its SHA-256 fingerprint.
    public static func make<Request: Encodable>(for request: Request) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Self.make(from: try encoder.encode(request))
    }
}
