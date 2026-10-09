import Foundation

/// The version of a runtime image bundle (runtime-image-manifest.md §2).
///
/// `YYYY.MM.N-<base>-<arch>`, for example `2026.10.0-cf16373615-arm64`. Ordering
/// uses the year, month, and sequence only; equality compares every part.
public struct ImageVersion: Comparable, Codable, Hashable, Sendable, CustomStringConvertible {
    /// The release year.
    public var year: Int
    /// The release month, 1 to 12.
    public var month: Int
    /// The sequence within the month, 0 to 999.
    public var sequence: Int
    /// The Android build, `cf<CI build>` or `ar<builder build>`. Informational.
    public var base: String
    /// The guest architecture. v1 has only `arm64`.
    public var architecture: String

    private static let pattern =
        #"^([0-9]{4})\.(0[1-9]|1[0-2])\.(0|[1-9][0-9]{0,2})-(cf[0-9]{1,20}|ar[0-9]{6})-(arm64)$"#

    /// Parses the full form; returns `nil` for anything the format rejects.
    public init?(_ text: String) {
        guard text.range(of: Self.pattern, options: .regularExpression) != nil else {
            return nil
        }
        let dashParts = text.split(separator: "-", maxSplits: 2).map(String.init)
        let triple = dashParts[0].split(separator: ".").compactMap { Int($0) }
        guard dashParts.count == 3, triple.count == 3 else {
            return nil
        }
        year = triple[0]
        month = triple[1]
        sequence = triple[2]
        base = dashParts[1]
        architecture = dashParts[2]
    }

    /// The canonical full form.
    public var description: String {
        String(format: "%04d.%02d.%d-%@-%@", year, month, sequence, base, architecture)
    }

    /// The short form `YYYY.MM.N`, used as the display name.
    public var shortForm: String {
        String(format: "%04d.%02d.%d", year, month, sequence)
    }

    /// Orders versions on year, month, and sequence only.
    public static func < (lhs: ImageVersion, rhs: ImageVersion) -> Bool {
        (lhs.year, lhs.month, lhs.sequence) < (rhs.year, rhs.month, rhs.sequence)
    }

    /// Decodes the value from JSON.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = ImageVersion(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid image version")
            )
        }
        self = version
    }

    /// Encodes the value as JSON.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
