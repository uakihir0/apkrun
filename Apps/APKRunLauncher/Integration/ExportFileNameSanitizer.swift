import Foundation
import UniformTypeIdentifiers

/// Applies the wrapper file-name rules to an Android-provided export name.
enum ExportFileNameSanitizer {
    private static let maximumUTF8Bytes = 200

    /// Returns a safe filename and adds the MIME type's preferred extension when needed.
    static func sanitize(
        _ offeredName: String,
        mimeType: String?,
        sourcePackageID: String
    ) -> String {
        let baseName = sanitizeBaseName(offeredName)
        let fallbackName = sourcePackageID.split(separator: ".").last.map(String.init) ?? "file"
        let safeBaseName = baseName.isEmpty ? sanitizeBaseName(fallbackName) : baseName
        let nonemptyBaseName = safeBaseName.isEmpty ? "file" : safeBaseName

        guard URL(fileURLWithPath: nonemptyBaseName).pathExtension.isEmpty,
            let fileExtension = preferredFilenameExtension(for: mimeType)
        else {
            return nonemptyBaseName
        }

        let suffix = ".\(fileExtension)"
        let maximumBaseBytes = maximumUTF8Bytes - suffix.utf8.count
        guard maximumBaseBytes > 0 else {
            return nonemptyBaseName
        }
        let truncatedBaseName = truncateAtCharacterBoundary(nonemptyBaseName, maximumUTF8Bytes: maximumBaseBytes)
        guard !truncatedBaseName.isEmpty else {
            guard "file".utf8.count <= maximumBaseBytes else {
                return nonemptyBaseName
            }
            return "file\(suffix)"
        }
        let finalBaseName = truncatedBaseName
        return "\(finalBaseName)\(suffix)"
    }

    private static func sanitizeBaseName(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let filteredScalars = normalized.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control:
                return false
            case .format:
                return scalar.value == 0x200D || isVariationSelector(scalar.value)
            default:
                return true
            }
        }

        let filtered = String(String.UnicodeScalarView(filteredScalars))
        let pathSafe =
            filtered
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let collapsedWhitespace = pathSafe.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = collapsedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutLeadingDots = String(trimmed.drop(while: { $0 == "." }))
        return truncateAtCharacterBoundary(withoutLeadingDots, maximumUTF8Bytes: maximumUTF8Bytes)
    }

    private static func preferredFilenameExtension(for mimeType: String?) -> String? {
        guard let mimeType else {
            return nil
        }
        let mediaType = mimeType.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mediaType,
            let fileExtension = UTType(mimeType: mediaType)?.preferredFilenameExtension,
            !fileExtension.isEmpty,
            fileExtension.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        else {
            return nil
        }
        return fileExtension
    }

    private static func truncateAtCharacterBoundary(_ value: String, maximumUTF8Bytes: Int) -> String {
        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = character.utf8.count
            guard byteCount + characterBytes <= maximumUTF8Bytes else {
                break
            }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func isVariationSelector(_ value: UInt32) -> Bool {
        (0xFE00...0xFE0F).contains(value) || (0xE0100...0xE01EF).contains(value)
    }
}
