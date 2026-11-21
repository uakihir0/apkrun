import APKStoreCore
import CryptoKit
import Foundation
import Security
import ZIPFoundation

/// A parsed `MANIFEST.MF`/`.SF` section: attribute values with the section's
/// exact byte range in the source file (the digest covers the raw bytes).
struct ManifestSection {
    /// The section bytes in the source, including the trailing blank line.
    var range: Range<Int>
    /// `Name:` value of a per-file section; nil on the main section.
    var name: String?
    /// Attribute name → value (continuations already joined).
    var attributes: [(String, String)]

    /// The first value for an attribute name.
    func value(_ attribute: String) -> String? {
        attributes.first(where: { $0.0 == attribute })?.1
    }
}

/// A JAR manifest or signature file: ordered sections, each with its raw
/// byte range (update-system.md §4.5 "Index verification").
struct ManifestDocument {
    /// The sections in file order.
    var sections: [ManifestSection]

    /// Parses `data` into sections split on blank lines. Line endings may be
    /// CRLF or LF. Each section range includes its trailing separator.
    init?(_ data: Data) {
        var sections: [ManifestSection] = []
        var cursor = 0
        var sectionStart = 0
        var attributes: [(String, String)] = []
        var lastKey: String?
        func endSection(at end: Int) {
            sections.append(
                ManifestSection(range: sectionStart..<end, name: nil, attributes: attributes))
        }
        while cursor < data.count {
            // Find the end of this line.
            var lineEnd = cursor
            while lineEnd < data.count, data[lineEnd] != 0x0A, data[lineEnd] != 0x0D {
                lineEnd += 1
            }
            var next = lineEnd
            if next < data.count, data[next] == 0x0D { next += 1 }
            if next < data.count, data[next] == 0x0A { next += 1 }
            let line = data[cursor..<lineEnd]
            if line.isEmpty {
                // Blank line: this section spans sectionStart..<next.
                endSection(at: next)
                sectionStart = next
                attributes = []
                lastKey = nil
            } else if line.first == 0x20 {
                // Continuation: append bytes after the leading space.
                guard let key = lastKey, !attributes.isEmpty,
                    let rest = String(data: line.dropFirst(), encoding: .utf8)
                else { return nil }
                attributes[attributes.count - 1].1 += rest
                _ = key
            } else {
                guard let colon = line.firstIndex(of: UInt8(ascii: ":")),
                    colon + 1 < lineEnd, line[colon + 1] == 0x20,
                    let key = String(data: line[..<colon], encoding: .utf8),
                    let value = String(data: line[(colon + 2)...], encoding: .utf8)
                else { return nil }
                attributes.append((key, value))
                lastKey = key
            }
            cursor = next
        }
        // A trailing section without a blank line is still a section.
        if sectionStart < data.count {
            endSection(at: data.count)
        }
        guard !sections.isEmpty else { return nil }
        self.sections = sections
    }
}

/// The `entry.jar` verifier of update-system.md §4.5 "Index verification":
/// ZIPFoundation reads the archive, CMSDecoder verifies the signature block
/// over the `.SF` file, the signer certificate's SHA-256 is compared to the
/// pinned fingerprint, then the `.SF` digests prove `MANIFEST.MF`, and the
/// manifest proves `entry.json`.
///
/// Structure violations (missing files, extra entries, size) are
/// `providerMetadataInvalid`; anything about the signature chain is
/// `providerSignatureInvalid`.
public enum FDroidIndexVerifier {
    /// The entry cap of §4.5.
    static let entryLimit = 16
    /// The total uncompressed byte cap of §4.5.
    static let byteLimit: Int64 = 16 * 1024 * 1024

    /// The digest attribute `.SF` and `MANIFEST.MF` carry for v2 indexes.
    static let digestAttribute = "SHA-256-Digest"

    /// The verified `entry.json` bytes inside `jar`, or a failure.
    public static func entryJSON(in jar: URL, fingerprint: APKStoreCore.SHA256Digest) throws(UpdateFailure)
        -> Data
    {
        guard let archive = try? Archive(url: jar, accessMode: .read) else {
            throw .providerMetadataInvalid(detail: "entry.jar: not a ZIP archive")
        }
        let entries = Array(archive)
        guard entries.count <= entryLimit else {
            throw .providerMetadataInvalid(detail: "entry.jar: over 16 entries")
        }
        var total: Int64 = 0
        for entry in entries {
            total += Int64(entry.uncompressedSize)
            guard total <= byteLimit else {
                throw .providerMetadataInvalid(detail: "entry.jar: over 16 MiB")
            }
        }

        var manifestData: Data?
        var sfName: String?
        var sfData: Data?
        var signatureData: Data?
        var entryData: Data?
        for entry in entries {
            let path = entry.path
            let data = try extract(entry, from: archive)
            if path == "META-INF/MANIFEST.MF" {
                manifestData = data
            } else if path.hasPrefix("META-INF/"), path.hasSuffix(".SF") {
                guard sfData == nil else {
                    throw .providerMetadataInvalid(detail: "entry.jar: more than one .SF")
                }
                sfName = String(path.dropLast(3))
                sfData = data
            } else if path.hasPrefix("META-INF/"),
                path.hasSuffix(".RSA") || path.hasSuffix(".DSA") || path.hasSuffix(".EC")
            {
                signatureData = data
            } else if path == "entry.json" {
                entryData = data
            }
        }
        guard let manifestData, let sfName, let sfData, let entryData else {
            throw .providerMetadataInvalid(
                detail: "entry.jar: needs MANIFEST.MF, one .SF, and entry.json")
        }
        guard let signatureData else {
            throw .providerSignatureInvalid(detail: "entry.jar: no signature block")
        }

        // 1. The CMS signature over the .SF bytes, then the signer's
        //    certificate SHA-256 against the pinned fingerprint.
        let certificate = try verifySignature(signatureData, over: sfData)
        guard APKStoreCore.SHA256Digest(data: certificate) == fingerprint else {
            throw .providerSignatureInvalid(detail: "entry.jar: signer fingerprint mismatch")
        }

        // 2. The .SF digests prove MANIFEST.MF.
        try verifyManifest(manifestData, against: sfData)

        // 3. The manifest proves entry.json.
        let document = ManifestDocument(manifestData)
        let entrySection = document?.sections.first(where: { $0.value("Name") == "entry.json" })
        guard let entrySection else {
            throw .providerSignatureInvalid(detail: "manifest: entry.json is not signed")
        }
        guard
            let expected = entrySection.value(digestAttribute).flatMap(Self.base64Data),
            Self.sha256(entryData) == expected
        else {
            throw .providerSignatureInvalid(detail: "manifest: entry.json digest mismatch")
        }
        return entryData
    }

    /// CMS-verifies `signature` over `content` and returns the signer's
    /// certificate DER when its SHA-256 is `fingerprint`.
    private static func verifySignature(_ signature: Data, over content: Data) throws(UpdateFailure)
        -> Data
    {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            throw .providerSignatureInvalid(detail: "CMSDecoderCreate failed")
        }
        guard CMSDecoderSetDetachedContent(decoder, content as CFData) == errSecSuccess else {
            throw .providerSignatureInvalid(detail: "entry.jar: detached content rejected")
        }
        var signatureBytes = Array(signature)
        guard CMSDecoderUpdateMessage(decoder, &signatureBytes, signature.count) == errSecSuccess,
            CMSDecoderFinalizeMessage(decoder) == errSecSuccess
        else {
            throw .providerSignatureInvalid(detail: "entry.jar: CMS message failed")
        }
        var count = 0
        guard CMSDecoderGetNumSigners(decoder, &count) == errSecSuccess, count == 1 else {
            throw .providerSignatureInvalid(detail: "entry.jar: expected exactly one signer")
        }
        var status = CMSSignerStatus.unsigned
        var trust: SecTrust?
        var certStatus = OSStatus()
        let policy = SecPolicyCreateBasicX509()
        guard
            CMSDecoderCopySignerStatus(
                decoder, 0, policy, false, &status, &trust, &certStatus) == errSecSuccess,
            status == .valid
        else {
            throw .providerSignatureInvalid(detail: "entry.jar: signature does not verify")
        }
        var certificate: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess,
            let certificate
        else {
            throw .providerSignatureInvalid(detail: "entry.jar: no signer certificate")
        }
        return SecCertificateCopyData(certificate) as Data
    }

    /// Verifies `MANIFEST.MF` against the `.SF` digests: the whole-manifest
    /// digest and/or per-section digests must hold (jarsigner writes both).
    private static func verifyManifest(_ manifest: Data, against sf: Data) throws(UpdateFailure) {
        guard let sfDocument = ManifestDocument(sf) else {
            throw .providerSignatureInvalid(detail: "entry.jar: malformed .SF")
        }
        guard let main = sfDocument.sections.first else {
            throw .providerSignatureInvalid(detail: "entry.jar: empty .SF")
        }
        let digestWhole = sha256(manifest)
        if let declared = main.value("SHA-256-Digest-Manifest").flatMap(Self.base64Data) {
            guard declared == digestWhole else {
                throw .providerSignatureInvalid(detail: ".SF: MANIFEST.MF digest mismatch")
            }
            return
        }
        // Per-section digests: each .SF entry section digests the manifest
        // section with the same `Name`, and the main section is covered by
        // SHA-256-Digest-Manifest-Main-Attributes. Without the whole-manifest
        // digest every named manifest section must be covered, or a signed
        // .SF that names other sections only would let the entry.json
        // section change under a valid signature.
        guard let manifestDocument = ManifestDocument(manifest) else {
            throw .providerSignatureInvalid(detail: "entry.jar: malformed MANIFEST.MF")
        }
        if let declared = main.value("SHA-256-Digest-Manifest-Main-Attributes")
            .flatMap(Self.base64Data)
        {
            guard let mainSection = manifestDocument.sections.first,
                sha256(manifest.subdata(in: mainSection.range)) == declared
            else {
                throw .providerSignatureInvalid(
                    detail: ".SF: manifest main-attributes digest mismatch")
            }
        }
        var covered = Set<String>()
        for section in sfDocument.sections.dropFirst() {
            guard let name = section.value("Name") else { continue }
            guard
                let manifestSection = manifestDocument.sections.first(where: {
                    $0.value("Name") == name
                })
            else {
                throw .providerSignatureInvalid(detail: ".SF: \(name) has no manifest section")
            }
            guard
                let declared = section.value(digestAttribute).flatMap(Self.base64Data),
                sha256(manifest.subdata(in: manifestSection.range)) == declared
            else {
                throw .providerSignatureInvalid(
                    detail: ".SF: \(name) section digest mismatch")
            }
            covered.insert(name)
        }
        for section in manifestDocument.sections {
            guard let name = section.value("Name") else { continue }
            guard covered.contains(name) else {
                throw .providerSignatureInvalid(
                    detail: ".SF: manifest section \(name) is not signed")
            }
        }
    }

    private static func extract(_ entry: Entry, from archive: Archive) throws(UpdateFailure)
        -> Data
    {
        do {
            var data = Data()
            data.reserveCapacity(Int(entry.uncompressedSize))
            try archive.extract(entry, consumer: { data.append($0) })
            return data
        } catch {
            throw .providerMetadataInvalid(detail: "entry.jar: cannot read \(entry.path)")
        }
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func base64Data(_ value: String) -> Data? {
        Data(base64Encoded: value)
    }
}
