import Foundation

/// Produces a safe file name for a Save to Mac panel from an Android-provided name.
public enum FileNameSanitizer {
    /// Sanitizes `name` according to wrapper.md §4.3 and uses the package's last segment if empty.
    public static func sanitize(_ name: String, packageID: String) -> String {
        let sanitized = sanitizeBase(name)
        guard !sanitized.isEmpty else {
            return packageID.split(separator: ".").last.map(String.init) ?? "file"
        }
        return sanitized
    }

    private static func sanitizeBase(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let filtered = String(
            normalized.unicodeScalars.filter { scalar in
                switch scalar.properties.generalCategory {
                case .control, .format:
                    scalar.value == 0x200D || isVariationSelector(scalar)
                default:
                    true
                }
            }
        )

        var replacedScalars = String.UnicodeScalarView()
        for scalar in filtered.unicodeScalars {
            replacedScalars.append(scalar == "/" || scalar == ":" ? "-" : scalar)
        }
        let replaced = String(replacedScalars)
        let collapsedWhitespace = replaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let candidate = String(collapsedWhitespace.drop(while: { $0 == "." }))

        var result = ""
        for character in candidate {
            let nextByteCount = result.utf8.count + character.utf8.count
            guard nextByteCount <= 200 else {
                break
            }
            result.append(character)
        }
        return result
    }

    private static func isVariationSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value)
            || (0xE0100...0xE01EF).contains(scalar.value)
    }
}
