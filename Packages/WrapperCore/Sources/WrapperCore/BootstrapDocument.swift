import CryptoKit
import Foundation
import RuntimeAPI

/// One APK file of `Contents/Resources/bootstrap/` (wrapper-json.md §3.2).
public struct BootstrapFileEntry: Codable, Sendable, Equatable {
    /// `base.apk`, or `split_<splitName>.apk`.
    public var name: String
    /// The file's SHA-256 digest, with the `sha256:` prefix.
    public var sha256: String
    /// Size in bytes, 1 to 2 GiB.
    public var size: Int64

    /// Creates a file entry.
    public init(name: String, sha256: String, size: Int64) {
        self.name = name
        self.sha256 = sha256
        self.size = size
    }
}

/// `bootstrap.json` of a portable wrapper (wrapper-json.md §3).
public struct BootstrapDocument: Codable, Sendable, Equatable {
    /// The only supported format version.
    public static let supportedFormatVersion = 1
    /// The most file entries a document may list (§3.2).
    public static let maximumFiles = 256
    /// The most signers a document may list (§3.2).
    public static let maximumSigners = 16
    /// The largest single file, 2 GiB (§3.2).
    public static let maximumFileBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// The largest summed payload, 8 GiB (§3.2).
    public static let maximumTotalBytes: Int64 = 8 * 1024 * 1024 * 1024
    /// The largest accepted JSON document (§3.4 B3).
    public static let maximumDocumentBytes = 64 * 1024

    /// The bootstrap format; always `1`.
    public var formatVersion: Int
    /// The Android package ID of the set.
    public var packageId: String
    /// The set's `versionCode`.
    public var versionCode: Int64
    /// The set's `versionName`, when the package has one.
    public var versionName: String?
    /// The set digest (package-store.md §3.3).
    public var setDigest: String
    /// The signer digests, unique and sorted ascending.
    public var signers: [String]
    /// `base.apk` first, then the splits sorted by split name.
    public var files: [BootstrapFileEntry]

    /// Creates a bootstrap document.
    public init(
        packageId: String,
        versionCode: Int64,
        versionName: String? = nil,
        setDigest: String,
        signers: [String],
        files: [BootstrapFileEntry]
    ) {
        self.formatVersion = Self.supportedFormatVersion
        self.packageId = packageId
        self.versionCode = versionCode
        self.versionName = versionName
        self.setDigest = setDigest
        self.signers = signers
        self.files = files
    }

    /// The summed size of `files` (the portable note prints it).
    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}

/// Why a `bootstrap.json` or its files are unusable (wrapper-json.md §3.4).
public enum BootstrapProblem: String, Sendable, Codable, Equatable {
    /// Bad JSON, over 64 KiB, an unsupported `formatVersion`, or a §3.5
    /// violation (including the file count).
    case malformed
    /// `packageId` or the inspected APKs do not match the registry's package.
    case packageMismatch
    /// A copied file's size or SHA-256, or the set digest, does not match.
    case hashMismatch
}

/// Why `importBootstrap` is refused before the JSON is read
/// (wrapper-json.md §3.4).
public enum BootstrapRefusal: String, Sendable, Codable, Equatable {
    /// The wrapper is not approved (registry state is not `active`).
    case notApproved
    /// The package is installed and not `uninstalledKeepingData`.
    case alreadyInstalled
}

/// A file name of `bootstrap/` (§3.2: `base.apk` or `split_<name>.apk` where
/// each segment of `name` is `[A-Za-z][A-Za-z0-9_]*` joined by `.`).
public enum BootstrapFileName {
    /// Whether `name` is a legal bootstrap file name.
    public static func isValid(_ name: String) -> Bool {
        if name == "base.apk" { return true }
        guard name.hasPrefix("split_"), name.hasSuffix(".apk"), name.count <= 255
        else { return false }
        let splitName = String(name.dropFirst("split_".count).dropLast(".apk".count))
        guard !splitName.isEmpty else { return false }
        return splitName.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { segment in
                guard let first = segment.first, first.isLetter else { return false }
                return segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
            }
    }

    /// The file name of a split: `split_config.arm64_v8a` →
    /// `split_config.arm64_v8a.apk`.
    public static func split(_ splitName: String) -> String {
        "split_\(splitName).apk"
    }
}

/// The §3.3 set digest: SHA-256 of the `name\thex\n` lines in file order.
public enum BootstrapSetDigest {
    /// Computes `sha256:<hex>` over the digest-input lines (§3.1).
    public static func compute(files: [BootstrapFileEntry]) -> String {
        var input = ""
        for file in files {
            input += "\(file.name)\t\(Self.hexPart(file.sha256))\n"
        }
        let digest = SHA256.hash(data: Data(input.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The hex part of a `sha256:`-prefixed digest (the whole string when the
    /// prefix is absent).
    public static func hexPart(_ digest: String) -> String {
        digest.hasPrefix("sha256:") ? String(digest.dropFirst("sha256:".count)) : digest
    }
}

/// Encodes and validates `bootstrap.json` (wrapper-json.md §3.2, §3.5).
/// Unknown fields are ignored on decode and never written.
public enum BootstrapDocumentCodec {
    /// Encodes with sorted keys (§1.3 deterministic encoding).
    public static func encode(_ document: BootstrapDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    /// Decodes and validates. Throws `.malformed` for bad JSON, an
    /// unsupported `formatVersion`, or any §3.2 violation.
    public static func decode(_ data: Data) throws(WrapperFailure) -> BootstrapDocument {
        guard data.count <= BootstrapDocument.maximumDocumentBytes else {
            throw .bootstrapInvalid(.malformed)
        }
        let document: BootstrapDocument
        do {
            document = try JSONDecoder().decode(BootstrapDocument.self, from: data)
        } catch {
            throw .bootstrapInvalid(.malformed)
        }
        try validate(document)
        return document
    }

    /// §3.2 field constraints, applied to a decoded or hand-built document.
    public static func validate(_ document: BootstrapDocument) throws(WrapperFailure) {
        guard document.formatVersion == BootstrapDocument.supportedFormatVersion,
            !document.packageId.isEmpty, document.packageId.count <= 255,
            document.versionCode >= 0,
            document.setDigest.hasPrefix("sha256:"),
            (1...BootstrapDocument.maximumSigners).contains(document.signers.count),
            Set(document.signers).count == document.signers.count,
            document.signers == document.signers.sorted(),
            (1...BootstrapDocument.maximumFiles).contains(document.files.count),
            document.files.first?.name == "base.apk",
            Set(document.files.map(\.name)).count == document.files.count
        else { throw .bootstrapInvalid(.malformed) }
        if let name = document.versionName, name.isEmpty || name.count > 1024 {
            throw .bootstrapInvalid(.malformed)
        }
        var total: Int64 = 0
        for file in document.files {
            guard BootstrapFileName.isValid(file.name),
                (1...BootstrapDocument.maximumFileBytes).contains(file.size),
                file.sha256.hasPrefix("sha256:")
            else { throw .bootstrapInvalid(.malformed) }
            total += file.size
            guard total <= BootstrapDocument.maximumTotalBytes else {
                throw .bootstrapInvalid(.malformed)
            }
        }
        for signer in document.signers where !signer.hasPrefix("sha256:") {
            throw .bootstrapInvalid(.malformed)
        }
    }
}

/// The APK set the generator clones into `Contents/Resources/bootstrap/`
/// (wrapper.md §10.1). RuntimeHost fills it from the package's `current/`
/// slot or an import ticket's files.
public struct BootstrapPayload: Sendable, Equatable {
    /// One payload file: its bootstrap name and its source on disk.
    public struct SourceFile: Sendable, Equatable {
        /// The file name inside `bootstrap/`.
        public var name: String
        /// The file to copy.
        public var sourceURL: URL
        /// The expected SHA-256, with the `sha256:` prefix.
        public var sha256: String
        /// The expected size.
        public var size: Int64

        /// Creates a payload file.
        public init(name: String, sourceURL: URL, sha256: String, size: Int64) {
            self.name = name
            self.sourceURL = sourceURL
            self.sha256 = sha256
            self.size = size
        }
    }

    /// `bootstrap.json` content.
    public var document: BootstrapDocument
    /// The files to clone, in `document.files` order.
    public var files: [SourceFile]

    /// Creates the payload. The source list must name exactly the document's
    /// files, in order.
    public init(document: BootstrapDocument, files: [SourceFile]) {
        self.document = document
        self.files = files
    }
}
