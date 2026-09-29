import Foundation

/// A random, process-independent identifier for one user-visible operation.
public struct OperationID: Codable, Hashable, Sendable, CustomStringConvertible {
    /// The canonical lowercase UUID v4 representation.
    public let rawValue: String

    /// Creates a fresh UUID v4 operation identifier.
    public init() {
        rawValue = UUID().uuidString.lowercased()
    }

    /// Parses a canonical lowercase UUID v4 received from a wire field.
    public init?(wire: String) {
        guard wire == wire.lowercased(),
            let uuid = UUID(uuidString: wire),
            uuid.uuidString.lowercased() == wire
        else {
            return nil
        }

        let groups = wire.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 5,
            groups[0].count == 8,
            groups[1].count == 4,
            groups[2].count == 4,
            groups[3].count == 4,
            groups[4].count == 12,
            groups[2].first == "4",
            let variant = groups[3].first,
            ["8", "9", "a", "b"].contains(variant)
        else {
            return nil
        }

        rawValue = wire
    }

    /// The first eight hexadecimal digits for human-readable output.
    public var short: String {
        String(rawValue.prefix(8))
    }

    /// The full string used by XPC headers and the guest envelope.
    public var wireValue: String {
        rawValue
    }

    /// The canonical wire representation.
    public var description: String {
        rawValue
    }

    /// Decodes a canonical lowercase UUID v4 string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let wire = try container.decode(String.self)
        guard let parsed = Self(wire: wire) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Operation ID must be a canonical lowercase UUID v4."
            )
        }
        self = parsed
    }

    /// Encodes the identifier as its canonical wire string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}
