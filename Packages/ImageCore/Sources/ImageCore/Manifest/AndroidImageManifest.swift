import Foundation

/// The reviewed build-time description of one Android image artifact set.
public struct AndroidImageManifest: Codable, Equatable, Sendable {
    /// The supported manifest schema version.
    public let schemaVersion: Int

    /// The source build and downloaded archives.
    public let source: Source

    /// Android release facts read from the image headers.
    public let android: Android

    /// The guest CPU architecture.
    public let architecture: String

    /// The device layout family selected by this manifest.
    public let deviceFamily: String

    /// The archive artifacts and their target partition names.
    public let artifacts: [Artifact]

    /// The roles assigned to artifact identifiers.
    public let roles: Roles

    /// Non-empty logical partitions inside the super partition.
    public let logicalPartitions: [LogicalPartition]

    /// Partitions that are created as zero-filled images.
    public let blankPartitions: [BlankPartition]

    /// String values copied from the source build's `android-info.txt`.
    public let androidInfo: [String: String]

    /// Provenance for a downloaded or APKRun-built source image.
    public struct Source: Codable, Equatable, Sendable {
        /// The build origin.
        public let origin: String

        /// The source branch or pinned AOSP manifest branch.
        public let branch: String

        /// The source build target, including its build variant.
        public let target: String

        /// The source build identifier.
        public let buildId: String

        /// Archives that supplied the inventory artifacts.
        public let archives: [Archive]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case origin
            case branch
            case target
            case buildId
            case archives
        }

        /// Decodes provenance while rejecting keys outside schema version 1.
        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            origin = try container.decode(String.self, forKey: .origin)
            branch = try container.decode(String.self, forKey: .branch)
            target = try container.decode(String.self, forKey: .target)
            buildId = try container.decode(String.self, forKey: .buildId)
            archives = try container.decode([Archive].self, forKey: .archives)
        }
    }

    /// Hash and size information for a source archive.
    public struct Archive: Codable, Equatable, Sendable {
        /// The archive's base name.
        public let name: String

        /// The archive size in bytes.
        public let size: Int

        /// The archive's lowercase SHA-256 digest.
        public let sha256: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case size
            case sha256
        }

        /// Decodes an archive record while rejecting unknown keys.
        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            size = try container.decode(Int.self, forKey: .size)
            sha256 = try container.decode(String.self, forKey: .sha256)
        }
    }

    /// Android release facts associated with this image.
    public struct Android: Codable, Equatable, Sendable {
        /// The Android release string.
        public let release: String

        /// The Android SDK/API level.
        public let sdk: Int

        /// The build variant.
        public let variant: String

        /// The security patch month in `YYYY-MM` form.
        public let securityPatch: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case release
            case sdk
            case variant
            case securityPatch
        }

        /// Decodes Android release facts while rejecting unknown keys.
        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            release = try container.decode(String.self, forKey: .release)
            sdk = try container.decode(Int.self, forKey: .sdk)
            variant = try container.decode(String.self, forKey: .variant)
            securityPatch = try container.decode(String.self, forKey: .securityPatch)
        }
    }

    /// An artifact and the partition to which the image tools assign it.
    public struct Artifact: Codable, Equatable, Sendable {
        /// The identifier referenced by `roles`.
        public let id: String

        /// The relative path inside the source archive.
        public let file: String

        /// The artifact's lowercase SHA-256 digest.
        public let sha256: String

        /// The artifact size in bytes.
        public let size: Int

        /// The inventory's content-based classification.
        public let kind: String

        /// The base partition name without a slot suffix.
        public let partition: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id
            case file
            case sha256
            case size
            case kind
            case partition
        }

        /// Decodes an artifact while rejecting unknown keys.
        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            file = try container.decode(String.self, forKey: .file)
            sha256 = try container.decode(String.self, forKey: .sha256)
            size = try container.decode(Int.self, forKey: .size)
            kind = try container.decode(String.self, forKey: .kind)
            partition = try container.decode(String.self, forKey: .partition)
        }
    }

    /// The manifest's semantic roles and their artifact identifiers.
    public struct Roles: Codable, Equatable, Sendable {
        /// The boot image that supplies the kernel.
        public let kernel: String

        /// The boot image that supplies the generic ramdisk.
        public let genericRamdisk: String

        /// The vendor boot image.
        public let vendorBoot: String

        /// The top-level vbmeta image followed by its chained vbmeta images.
        public let vbmeta: [String]

        /// The dynamic-partition super image.
        public let `super`: String

        /// An optional filesystem image used by userdata fallback A.
        public let userdataTemplate: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kernel
            case genericRamdisk
            case vendorBoot
            case vbmeta
            case `super`
            case userdataTemplate
        }

        /// Decodes role mappings while rejecting unknown keys.
        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kernel = try container.decode(String.self, forKey: .kernel)
            genericRamdisk = try container.decode(String.self, forKey: .genericRamdisk)
            vendorBoot = try container.decode(String.self, forKey: .vendorBoot)
            vbmeta = try container.decode([String].self, forKey: .vbmeta)
            `super` = try container.decode(String.self, forKey: .super)
            if container.contains(.userdataTemplate) {
                userdataTemplate = try container.decode(String.self, forKey: .userdataTemplate)
            } else {
                userdataTemplate = nil
            }
        }
    }

    /// One non-empty logical partition inside `super`.
    public struct LogicalPartition: Codable, Equatable, Sendable {
        /// The liblp partition name, including its slot suffix.
        public let name: String

        /// The logical partition size in bytes.
        public let size: Int

        /// The detected filesystem.
        public let filesystem: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case size
            case filesystem
        }

        /// Decodes a logical partition while rejecting unknown keys.
        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            size = try container.decode(Int.self, forKey: .size)
            filesystem = try container.decode(String.self, forKey: .filesystem)
        }
    }

    /// A partition created as a zero-filled image.
    public struct BlankPartition: Codable, Equatable, Sendable {
        /// The base partition name.
        public let partition: String

        /// The blank partition size in bytes.
        public let size: Int

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case partition
            case size
        }

        /// Decodes a blank partition while rejecting unknown keys.
        public init(from decoder: any Decoder) throws {
            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            partition = try container.decode(String.self, forKey: .partition)
            size = try container.decode(Int.self, forKey: .size)
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case source
        case android
        case architecture
        case deviceFamily
        case artifacts
        case roles
        case logicalPartitions
        case blankPartitions
        case androidInfo
    }

    /// Decodes the schema version first, then the closed schema and its field constraints.
    public init(from decoder: any Decoder) throws {
        do {
            let dynamicContainer = try decoder.container(keyedBy: ManifestCodingKey.self)
            let schemaVersion = try dynamicContainer.decode(
                Int.self,
                forKey: ManifestCodingKey(string: "schemaVersion")
            )
            guard schemaVersion == 1 else {
                let reason =
                    schemaVersion > 1
                    ? "android-image.json: schemaVersion \(schemaVersion) is newer than this tool supports (1). Update Images/tools."
                    : "android-image.json: schemaVersion \(schemaVersion) is invalid; supported version is 1."
                throw ImageFailure.manifestInvalid(path: "android-image.json", reason: reason)
            }

            try rejectUnknownKeys(in: decoder, allowed: CodingKeys.allCases)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = schemaVersion
            source = try container.decode(Source.self, forKey: .source)
            android = try container.decode(Android.self, forKey: .android)
            architecture = try container.decode(String.self, forKey: .architecture)
            deviceFamily = try container.decode(String.self, forKey: .deviceFamily)
            artifacts = try container.decode([Artifact].self, forKey: .artifacts)
            roles = try container.decode(Roles.self, forKey: .roles)
            logicalPartitions = try container.decode(
                [LogicalPartition].self,
                forKey: .logicalPartitions
            )
            blankPartitions = try container.decode([BlankPartition].self, forKey: .blankPartitions)
            androidInfo = try container.decode([String: String].self, forKey: .androidInfo)
            try validateSchema(self)
        } catch let failure as ImageFailure {
            throw failure
        } catch {
            throw manifestDecodingFailure(error)
        }
    }
}

private struct ManifestCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(string: String) {
        stringValue = string
        intValue = nil
    }

    init(index: Int) {
        stringValue = "Index \(index)"
        intValue = index
    }

    init?(stringValue: String) {
        self.init(string: stringValue)
    }

    init?(intValue: Int) {
        self.init(index: intValue)
    }
}

private func manifestDecodingFailure(_ error: any Error) -> ImageFailure {
    let reason: String
    switch error {
    case DecodingError.typeMismatch(let type, let context):
        let location = manifestDecodingLocation(context.codingPath)
        reason =
            "\(location): expected \(String(describing: type)), found an incompatible JSON type. "
            + "Correct the field type to match schema version 1."
    case DecodingError.valueNotFound(let type, let context):
        let location = manifestDecodingLocation(context.codingPath)
        reason =
            "\(location): expected \(String(describing: type)), found null. "
            + "Provide a value matching schema version 1."
    case DecodingError.keyNotFound(let key, let context):
        let location = manifestDecodingLocation(context.codingPath + [key])
        reason = "\(location): required field is missing. Add this field to the manifest."
    case DecodingError.dataCorrupted(let context):
        let location = manifestDecodingLocation(context.codingPath)
        reason = "\(location): value is malformed for schema version 1. Check the field format."
    default:
        reason =
            "android-image.json: could not decode the document as schema version 1. "
            + "Check its JSON structure and field types."
    }
    return .manifestInvalid(path: "android-image.json", reason: reason)
}

private func manifestDecodingLocation(_ codingPath: [any CodingKey]) -> String {
    var location = "android-image.json"
    for key in codingPath {
        if let index = key.intValue {
            location += "[\(index)]"
        } else if location == "android-image.json" {
            location += ":\(manifestDiagnosticValue(key.stringValue))"
        } else {
            location += ".\(manifestDiagnosticValue(key.stringValue))"
        }
    }
    return location
}

private func rejectUnknownKeys<Key: CodingKey>(
    in decoder: any Decoder,
    allowed: [Key]
) throws {
    let container = try decoder.container(keyedBy: ManifestCodingKey.self)
    let allowedNames = Set(allowed.map(\.stringValue))
    guard
        let unknownKey = container.allKeys
            .map(\.stringValue)
            .filter({ !allowedNames.contains($0) })
            .sorted()
            .first
    else {
        return
    }

    let objectPath = decoder.codingPath
        .map { manifestDiagnosticValue($0.stringValue) }
        .joined(separator: ".")
    let location = objectPath.isEmpty ? "android-image.json" : "android-image.json:\(objectPath)"
    let reason =
        "\(location): unknown field \"\(manifestDiagnosticValue(unknownKey))\". "
        + "Remove it or use schema version 1."
    throw ImageFailure.manifestInvalid(path: "android-image.json", reason: reason)
}

func manifestDiagnosticValue(_ value: String) -> String {
    let scalars = Array(value.unicodeScalars.prefix(128))
    var escaped = ""
    for scalar in scalars {
        switch scalar.value {
        case 0x22:
            escaped += "\\\""
        case 0x5C:
            escaped += "\\\\"
        case 0x00...0x1F, 0x7F...0x9F, 0x061C, 0x200E, 0x200F, 0x2028, 0x2029,
            0x202A...0x202E, 0x2066...0x2069:
            let codePoint = String(scalar.value, radix: 16).uppercased()
            escaped += "\\u{\(codePoint)}"
        default:
            escaped.unicodeScalars.append(scalar)
        }
    }
    if value.unicodeScalars.count > scalars.count {
        escaped += "…"
    }
    return escaped
}

private func validateSchema(_ manifest: AndroidImageManifest) throws {
    try requireManifest(
        manifest.source.origin == "ci.android.com" || manifest.source.origin == "apkrun-builder",
        path: "source.origin",
        expected: "\"ci.android.com\" or \"apkrun-builder\"",
        found: manifest.source.origin
    )
    try requireManifest(
        matches(manifest.source.branch, pattern: "^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"),
        path: "source.branch",
        expected: "a 1–128 character branch identifier",
        found: manifest.source.branch
    )
    try requireManifest(
        manifest.source.target.unicodeScalars.count <= 128
            && matches(manifest.source.target, pattern: "^[a-z0-9][a-z0-9_-]*-(user|userdebug|eng)$"),
        path: "source.target",
        expected: "a product name followed by -user, -userdebug, or -eng",
        found: manifest.source.target
    )
    try requireManifest(
        matches(manifest.source.buildId, pattern: "^([0-9]{1,20}|ar[0-9]{6})$"),
        path: "source.buildId",
        expected: "a numeric build ID or ar followed by six digits",
        found: manifest.source.buildId
    )
    try requireManifest(
        (1...8).contains(manifest.source.archives.count),
        path: "source.archives",
        expected: "1–8 archive records",
        found: "\(manifest.source.archives.count) records"
    )
    for (index, archive) in manifest.source.archives.enumerated() {
        let path = "source.archives[\(index)]"
        try requireManifest(
            matches(archive.name, pattern: "^[A-Za-z0-9._+-]{1,255}$"),
            path: "\(path).name",
            expected: "a 1–255 character archive base name",
            found: archive.name
        )
        try requireManifest(
            archive.size >= 1,
            path: "\(path).size",
            expected: "at least 1 byte",
            found: "\(archive.size)"
        )
        try requireManifest(
            isSHA256(archive.sha256),
            path: "\(path).sha256",
            expected: "64 lowercase hexadecimal characters",
            found: archive.sha256
        )
    }

    try requireManifest(
        matches(manifest.android.release, pattern: "^[1-9][0-9]*(\\.[0-9]+){0,2}$"),
        path: "android.release",
        expected: "a numeric Android release",
        found: manifest.android.release
    )
    try requireManifest(
        (1...10_000).contains(manifest.android.sdk),
        path: "android.sdk",
        expected: "an integer from 1 to 10000",
        found: "\(manifest.android.sdk)"
    )
    try requireManifest(
        ["user", "userdebug", "eng"].contains(manifest.android.variant),
        path: "android.variant",
        expected: "user, userdebug, or eng",
        found: manifest.android.variant
    )
    try requireManifest(
        matches(manifest.android.securityPatch, pattern: "^[0-9]{4}-(0[1-9]|1[0-2])$"),
        path: "android.securityPatch",
        expected: "a month in YYYY-MM form",
        found: manifest.android.securityPatch
    )
    try requireManifest(
        matches(manifest.architecture, pattern: "^[a-z0-9_]{1,32}$"),
        path: "architecture",
        expected: "1–32 lowercase letters, digits, or underscores",
        found: manifest.architecture
    )
    try requireManifest(
        manifest.deviceFamily.unicodeScalars.count <= 64
            && matches(manifest.deviceFamily, pattern: "^[a-z0-9]+(-[a-z0-9]+)*$"),
        path: "deviceFamily",
        expected: "a lowercase hyphen-separated name of at most 64 characters",
        found: manifest.deviceFamily
    )

    try requireManifest(
        (1...64).contains(manifest.artifacts.count),
        path: "artifacts",
        expected: "1–64 artifact records",
        found: "\(manifest.artifacts.count) records"
    )
    for (index, artifact) in manifest.artifacts.enumerated() {
        let path = "artifacts[\(index)]"
        try requireManifest(
            matches(artifact.id, pattern: "^[a-z][a-z0-9_]{0,35}$"),
            path: "\(path).id",
            expected: "a lowercase artifact identifier of at most 36 characters",
            found: artifact.id
        )
        try requireManifest(
            artifact.file.unicodeScalars.count <= 255
                && matches(artifact.file, pattern: "^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$")
                && artifact.file.split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ $0 != "." && $0 != ".." }),
            path: "\(path).file",
            expected: "a safe relative archive path of at most 255 characters",
            found: artifact.file
        )
        try requireManifest(
            isSHA256(artifact.sha256),
            path: "\(path).sha256",
            expected: "64 lowercase hexadecimal characters",
            found: artifact.sha256
        )
        try requireManifest(
            artifact.size >= 1,
            path: "\(path).size",
            expected: "at least 1 byte",
            found: "\(artifact.size)"
        )
        try requireManifest(
            [
                "bootImage",
                "vendorBootImage",
                "vbmeta",
                "sparse",
                "dynamicPartitions",
                "filesystem",
                "unknown",
            ].contains(artifact.kind),
            path: "\(path).kind",
            expected: "a supported inventory kind",
            found: artifact.kind
        )
        try requireManifest(
            matches(artifact.partition, pattern: "^[a-z][a-z0-9_]{0,33}$"),
            path: "\(path).partition",
            expected: "a lowercase partition name of at most 34 characters",
            found: artifact.partition
        )
    }

    for (role, identifier) in [
        ("roles.kernel", manifest.roles.kernel),
        ("roles.genericRamdisk", manifest.roles.genericRamdisk),
        ("roles.vendorBoot", manifest.roles.vendorBoot),
        ("roles.super", manifest.roles.super),
    ] {
        try requireManifest(
            matches(identifier, pattern: "^[a-z][a-z0-9_]{0,35}$"),
            path: role,
            expected: "a lowercase artifact identifier of at most 36 characters",
            found: identifier
        )
    }
    if let identifier = manifest.roles.userdataTemplate {
        try requireManifest(
            matches(identifier, pattern: "^[a-z][a-z0-9_]{0,35}$"),
            path: "roles.userdataTemplate",
            expected: "a lowercase artifact identifier of at most 36 characters",
            found: identifier
        )
    }
    try requireManifest(
        (1...16).contains(manifest.roles.vbmeta.count),
        path: "roles.vbmeta",
        expected: "1–16 artifact identifiers",
        found: "\(manifest.roles.vbmeta.count) identifiers"
    )
    for (index, identifier) in manifest.roles.vbmeta.enumerated() {
        try requireManifest(
            matches(identifier, pattern: "^[a-z][a-z0-9_]{0,35}$"),
            path: "roles.vbmeta[\(index)]",
            expected: "a lowercase artifact identifier of at most 36 characters",
            found: identifier
        )
    }
    try requireManifest(
        Set(manifest.roles.vbmeta).count == manifest.roles.vbmeta.count,
        path: "roles.vbmeta",
        expected: "unique artifact identifiers",
        found: manifest.roles.vbmeta.joined(separator: ", ")
    )

    try requireManifest(
        (1...64).contains(manifest.logicalPartitions.count),
        path: "logicalPartitions",
        expected: "1–64 logical partition records",
        found: "\(manifest.logicalPartitions.count) records"
    )
    for (index, partition) in manifest.logicalPartitions.enumerated() {
        let path = "logicalPartitions[\(index)]"
        try requireManifest(
            matches(partition.name, pattern: "^[a-z][a-z0-9_]{0,35}$"),
            path: "\(path).name",
            expected: "a lowercase logical partition name of at most 36 characters",
            found: partition.name
        )
        try requireManifest(
            partition.size >= 512 && partition.size.isMultiple(of: 512),
            path: "\(path).size",
            expected: "a positive multiple of 512 bytes",
            found: "\(partition.size)"
        )
        try requireManifest(
            ["ext4", "erofs", "f2fs", "unknown"].contains(partition.filesystem),
            path: "\(path).filesystem",
            expected: "ext4, erofs, f2fs, or unknown",
            found: partition.filesystem
        )
    }

    try requireManifest(
        manifest.blankPartitions.count <= 32,
        path: "blankPartitions",
        expected: "0–32 blank partition records",
        found: "\(manifest.blankPartitions.count) records"
    )
    for (index, partition) in manifest.blankPartitions.enumerated() {
        let path = "blankPartitions[\(index)]"
        try requireManifest(
            matches(partition.partition, pattern: "^[a-z][a-z0-9_]{0,33}$"),
            path: "\(path).partition",
            expected: "a lowercase partition name of at most 34 characters",
            found: partition.partition
        )
        try requireManifest(
            partition.size >= 4_096 && partition.size.isMultiple(of: 4_096),
            path: "\(path).size",
            expected: "a positive multiple of 4096 bytes",
            found: "\(partition.size)"
        )
    }
    for (key, value) in manifest.androidInfo {
        try requireManifest(
            key.unicodeScalars.count <= 64 && matches(key, pattern: "^[A-Za-z0-9_.-]{1,64}$"),
            path: "androidInfo",
            expected: "keys of 1–64 ASCII letters, digits, underscores, dots, or hyphens",
            found: key
        )
        try requireManifest(
            value.unicodeScalars.count <= 1_024,
            path: "androidInfo.\(manifestDiagnosticValue(key))",
            expected: "a string of at most 1024 characters",
            found: "\(value.unicodeScalars.count) characters"
        )
    }
}

private func matches(_ value: String, pattern: String) -> Bool {
    guard let match = value.range(of: pattern, options: .regularExpression) else {
        return false
    }
    return match.lowerBound == value.startIndex && match.upperBound == value.endIndex
}

private func isSHA256(_ value: String) -> Bool {
    matches(value, pattern: "^[0-9a-f]{64}$")
}

private func requireManifest(
    _ condition: Bool,
    path: String,
    expected: String,
    found: String
) throws {
    guard !condition else {
        return
    }
    let reason =
        "android-image.json: \(path) must be \(expected); "
        + "found \"\(manifestDiagnosticValue(found))\"."
    throw ImageFailure.manifestInvalid(path: "android-image.json", reason: reason)
}
