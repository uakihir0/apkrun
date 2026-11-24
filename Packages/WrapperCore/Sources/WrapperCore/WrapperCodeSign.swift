import Foundation
import Security

/// Code-signature inspection for launcher templates and generated bundles.
/// Local re-signing itself is #47 (wrapper.md §7.1); these helpers read what
/// the signature already carries.
public enum WrapperCodeSign {
    /// The CDHash (SHA-256 code directory hash) of the main executable of a
    /// bundle, as 40 lowercase hex characters, or `nil` when it is unsigned.
    public static func cdhash(of bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
            let code = staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
            let dictionary = info as? [String: Any],
            let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// The identifier recorded in the bundle's code signature, or `nil` when
    /// it is unsigned. Used by the quick verification path; `deep` runs the
    /// strict check instead (wrapper.md §9.1).
    public static func signatureIdentifier(of bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
            let code = staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoIdentifier as String] as? String
    }

    /// Whether the code signature of a bundle is strictly valid and names the
    /// expected identifier (`SecStaticCodeCheckValidity`, strict, all
    /// architectures, `identifier "<bundleID>"`).
    public static func signatureIsValid(bundleURL: URL, identifier: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
            let code = staticCode
        else { return false }
        var requirement: SecRequirement?
        let requirementText = "identifier \"\(identifier)\""
        guard
            SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
                == errSecSuccess
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Whether the signature of a bundle is strictly valid without an
    /// identifier requirement.
    public static func signatureIsValid(bundleURL: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
            let code = staticCode
        else { return false }
        return SecStaticCodeCheckValidity(
            code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
            nil) == errSecSuccess
    }

    /// The team identifier recorded in the bundle's code signature, or `nil`
    /// when it is unsigned (wrapper.md §11 `DistributionWrapperResult.teamID`).
    public static func teamID(of bundleURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
            let code = staticCode
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether a Mach-O file is an arm64 executable or a universal binary that
    /// includes arm64 (wrapper.md §5.1).
    public static func isARM64(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else {
            return false
        }
        // Thin Mach-O headers are little-endian; fat headers are big-endian.
        let magic = header.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        // CPU_TYPE_ARM64 = CPU_ARCH_ABI64 | 12
        let arm64: UInt32 = 0x0100_000C
        switch magic {
        case 0xFEED_FACF, 0xFEED_FACE:
            // Thin Mach-O: cputype follows the magic.
            let cpu = header.dropFirst(4).prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
            return cpu == arm64
        case 0xCAFE_BABE:
            // Fat binary: nfat_arch then fat_arch records (cputype, cpusubtype,
            // offset, size, align), 20 bytes each.
            let count = header.dropFirst(4).prefix(4).withUnsafeBytes {
                $0.load(as: UInt32.self)
            }.bigEndian
            var offset = 8
            for _ in 0..<min(count, 64) {
                guard header.count >= offset + 4 else { return false }
                let cpu = header.dropFirst(offset).prefix(4).withUnsafeBytes {
                    $0.load(as: UInt32.self)
                }.bigEndian
                if cpu == arm64 { return true }
                offset += 20
            }
            return false
        default:
            return false
        }
    }
}
