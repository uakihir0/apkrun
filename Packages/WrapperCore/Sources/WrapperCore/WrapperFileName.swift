import Foundation
import RuntimeAPI

/// The sanitized bundle file name for a wrapper (wrapper.md §4.3).
public enum WrapperFileName {
    /// The byte cap of the name before `.app` is appended.
    public static let maximumUTF8Bytes = 200

    /// Returns the `<name>` of `<name>.app` for a display name.
    ///
    /// 1. Unicode NFC; control and format characters (Cc, Cf) are removed except
    ///    the zero width joiner and variation selectors, so emoji sequences survive.
    /// 2. `/` and `:` become `-`, whitespace runs collapse to one space, the result
    ///    is trimmed, and leading `.` characters are removed.
    /// 3. The name is cut to 200 UTF-8 bytes at a grapheme-cluster boundary.
    /// 4. An empty result falls back to the last segment of the package ID.
    public static func sanitize(displayName: String, packageID: String) -> String {
        var name = displayName.precomposedStringWithCanonicalMapping
        name = String(
            name.unicodeScalars.filter { scalar in
                guard
                    CharacterSet.controlCharacters.contains(scalar)
                        || (scalar.properties.generalCategory == .format)
                else { return true }
                return scalar.value == 0x200D
                    || (0xFE00...0xFE0F).contains(scalar.value)
                    || (0xE0100...0xE01EF).contains(scalar.value)
            }
            .map(Character.init)
        )
        name = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        name = truncateToUTF8ByteLimit(name, limit: maximumUTF8Bytes)
        if name.isEmpty {
            name = packageID.split(separator: ".").last.map(String.init) ?? "app"
        }
        return name
    }

    /// Returns the `CFBundleDisplayName` value: the display name after step 1 only.
    public static func sanitizedDisplayName(_ displayName: String) -> String {
        let normalized = displayName.precomposedStringWithCanonicalMapping
        return String(
            normalized.unicodeScalars.filter { scalar in
                guard
                    CharacterSet.controlCharacters.contains(scalar)
                        || (scalar.properties.generalCategory == .format)
                else { return true }
                return scalar.value == 0x200D
                    || (0xFE00...0xFE0F).contains(scalar.value)
                    || (0xE0100...0xE01EF).contains(scalar.value)
            }
            .map(Character.init)
        )
    }

    /// Cuts a string to at most `limit` UTF-8 bytes without splitting a grapheme.
    private static func truncateToUTF8ByteLimit(_ string: String, limit: Int) -> String {
        var result = ""
        var bytes = 0
        for character in string {
            let length = String(character).utf8.count
            guard bytes + length <= limit else { break }
            result.append(character)
            bytes += length
        }
        return result
    }
}
