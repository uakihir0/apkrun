import CryptoKit
import Foundation

/// A log message whose interpolated values must state their privacy.
public struct LogMessage: CustomReflectable, CustomStringConvertible, ExpressibleByStringInterpolation, Sendable {
    /// Builds the public and private representations of an interpolated message.
    public struct StringInterpolation: CustomReflectable, CustomStringConvertible, StringInterpolationProtocol {
        private var publicValue: String
        private var privateValue: String
        private var containsPrivateValue: Bool

        /// A safe description that excludes the private representation.
        public var description: String { "<log message interpolation>" }

        /// Exposes only the public representation to reflection.
        public var customMirror: Mirror {
            Mirror(
                self,
                children: [("publicText", publicValue)],
                displayStyle: .struct,
                ancestorRepresentation: .suppressed
            )
        }

        /// Reserves storage for a message with the given literal and interpolation sizes.
        public init(literalCapacity: Int, interpolationCount: Int) {
            publicValue = ""
            publicValue.reserveCapacity(literalCapacity + interpolationCount * 16)
            privateValue = ""
            privateValue.reserveCapacity(literalCapacity + interpolationCount * 16)
            containsPrivateValue = false
        }

        /// Appends literal text to both representations.
        public mutating func appendLiteral(_ literal: String) {
            let safeLiteral = Self.escapedSeparator(in: literal)
            publicValue.append(safeLiteral)
            privateValue.append(safeLiteral)
        }

        /// Appends a value using the explicitly selected privacy classification.
        public mutating func appendInterpolation<Value: CustomStringConvertible>(
            _ value: Value,
            _ privacy: LogPrivacy
        ) {
            let safeValue = Self.escapedSeparator(in: String(describing: value))
            switch privacy {
            case .public:
                publicValue.append(safeValue)
                privateValue.append(safeValue)
            case .private:
                publicValue.append("<private>")
                privateValue.append(safeValue)
                containsPrivateValue = true
            case .hashed:
                let digest = LogMessage.processLocalDigest(for: safeValue)
                publicValue.append(digest)
                privateValue.append(digest)
            }
        }

        /// Rejects values marked sensitive even when a privacy label is supplied.
        @available(*, unavailable, message: "Sensitive values must never be interpolated into log messages.")
        public mutating func appendInterpolation<Value: Sendable>(
            _ value: Sensitive<Value>,
            _ privacy: LogPrivacy
        ) {}

        fileprivate var publicText: String { publicValue }
        fileprivate var privateText: String? { containsPrivateValue ? privateValue : nil }

        private static func escapedSeparator(in value: String) -> String {
            value.replacingOccurrences(of: "\u{1F}", with: "\\u{001F}")
        }
    }

    /// The text safe for public logs and file mirrors.
    let publicText: String

    /// The full text, present only when the message contains private values.
    let privateText: String?

    /// A safe description that never includes the private representation.
    public var description: String { "<log message>" }

    /// Exposes only the public representation to reflection.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [("publicText", publicText)],
            displayStyle: .struct,
            ancestorRepresentation: .suppressed
        )
    }

    /// Creates a literal message with no interpolated values.
    public init(stringLiteral value: String) {
        let safeValue = value.replacingOccurrences(of: "\u{1F}", with: "\\u{001F}")
        publicText = safeValue
        privateText = nil
    }

    /// Creates a message from a custom string interpolation.
    public init(stringInterpolation: StringInterpolation) {
        publicText = stringInterpolation.publicText
        privateText = stringInterpolation.privateText
    }

    fileprivate static func processLocalDigest(for value: String) -> String {
        let data = Data((processSalt + value).utf8)
        let digest = SHA256.hash(data: data)
        return "#" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static let processSalt = UUID().uuidString
}
