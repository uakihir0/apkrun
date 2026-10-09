import Foundation

/// Reads the kernel's `/proc/bootconfig` listing (android-image.md §6.1).
///
/// The parser accepts `key = "value";` lines and `name {` ... `}` blocks, so it does not depend on
/// whether the kernel prints dotted keys flat or nested. It returns dotted keys mapped to values.
enum BootconfigListing {
    /// The key/value pairs of `listing`, with each key's nested blocks joined by dots.
    static func keyValues(in listing: String) -> [String: String] {
        var values: [String: String] = [:]
        var prefix: [String] = []
        for rawLine in listing.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("}") {
                _ = prefix.popLast()
                continue
            }
            if line.hasSuffix("{") {
                prefix.append(line.dropLast().trimmingCharacters(in: .whitespaces))
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                continue
            }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") {
                value.removeLast()
            }
            value = value.trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values[(prefix + [name]).joined(separator: ".")] = value
        }
        return values
    }
}
