import Foundation

/// `manifest.json` of a runtime image bundle (runtime-image-manifest.md §4).
///
/// Decoding is strict: an unknown key, a missing required key, or a value of the wrong
/// type fails (§11). The value rules (patterns, ranges, and S1–S14) run after decoding in
/// `RuntimeImageManifest.load(_:)`, so a document is accepted only when both pass.
public struct RuntimeImageManifest: Codable, Equatable, Sendable {
    /// The manifest format version (§11). Only 1 is defined.
    public var schemaVersion: Int
    /// The bundle's version; equals its directory name.
    public var imageVersion: ImageVersion
    /// Whether this is a stock development image or the APKRun product.
    public var kind: Kind
    /// Where the bundle came from (§4.3).
    public var provenance: Provenance
    /// Guest facts for package checks before the first boot (§4.3).
    public var guest: Guest
    /// The direct-boot files (§4.4).
    public var boot: Boot
    /// The read-only disks, attached first (§4.5).
    public var disks: [Disk]
    /// The templates of the per-instance disks (§4.5).
    public var templates: [Disk]
    /// The console port plan in guest order (§4.6).
    public var consolePorts: [ConsolePort]
    /// The GPU profiles by name (§4.7).
    public var gpuProfiles: [String: GPUProfile]
    /// What the host must provide (§4.8).
    public var requirements: Requirements
    /// Userdata schema compatibility (§4.9).
    public var userdata: Userdata
    /// Which images may migrate to this one (§4.9).
    public var compatibility: Compatibility
    /// The notices file of a release bundle (§4.2). Absent in stock bundles.
    public var legal: Legal?
    /// Every bundle file except the metadata files, sorted by path (§4.10).
    public var files: [FileEntry]

    /// Whether the bundle is a ci.android.com build (development only) or the APKRun product.
    public enum Kind: String, Codable, Sendable {
        case stock
        case apkrun
    }

    /// A bundle file with its size and SHA-256 (§4.10).
    public struct FileEntry: Codable, Equatable, Sendable {
        /// The bundle-relative path.
        public var path: String
        /// The size in bytes; for sparse files, the logical size.
        public var size: UInt64
        /// The SHA-256 in lowercase hex.
        public var sha256: String

        enum CodingKeys: String, CodingKey, CaseIterable { case path, size, sha256 }
    }

    /// The direct-boot files (§4.4).
    public struct Boot: Codable, Equatable, Sendable {
        /// The uncompressed arm64 Image.
        public var kernel: FileEntry
        /// The initrd without a bootconfig trailer.
        public var ramdisk: FileEntry
        /// The bootconfig layers 1 and 2, or this profile's layer-2 keys.
        public var bootconfig: FileEntry
        /// The exact kernel command line.
        public var cmdline: FileEntry
        /// The page size from the kernel header: 4096, 16384, or 65536.
        public var kernelPageSize: Int
        /// Layer-1 keys that the image layer may override.
        public var bootconfigOverrides: [String]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case kernel, ramdisk, bootconfig, cmdline, kernelPageSize, bootconfigOverrides
        }
    }

    /// One raw GPT disk (§4.5).
    public struct Disk: Codable, Equatable, Sendable {
        /// What the disk is for: `os` or `userdata`.
        public var role: String
        /// The bundle-relative path.
        public var path: String
        /// Whether VZ attaches the disk read-only.
        public var readOnly: Bool
        /// The block device identifier for logs.
        public var identifier: String
        /// The disk size in bytes; for userdata, the template size before growth.
        public var logicalSize: UInt64
        /// How the userdata template becomes /data. Present only for userdata.
        public var userdataStrategy: UserdataStrategy?
        /// The GPT partitions in on-disk order.
        public var partitions: [Partition]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case role, path, readOnly, identifier, logicalSize, userdataStrategy, partitions
        }

        /// One GPT partition of a disk.
        public struct Partition: Codable, Equatable, Sendable {
            /// The GPT name, seen as /dev/block/by-name/<label>.
            public var label: String
            /// The first sector.
            public var firstLBA: UInt64
            /// The size in bytes.
            public var size: UInt64
            /// The SHA-256 of the partition contents.
            public var sha256: String

            enum CodingKeys: String, CodingKey, CaseIterable { case label, firstLBA, size, sha256 }
        }
    }

    /// How the userdata template becomes `/data` (§4.5, android-image.md §5.2).
    public enum UserdataStrategy: String, Codable, Sendable {
        case blankFormattable
        case prebuiltTemplate
    }

    /// One console port of the plan (§4.6).
    public struct ConsolePort: Codable, Equatable, Sendable {
        /// The guest hvcN number.
        public var index: Int
        /// The default console role of the port.
        public var role: Role
        /// The role's name, such as logcat.
        public var name: String

        enum CodingKeys: String, CodingKey, CaseIterable { case index, role, name }

        /// The default console role of a port.
        public enum Role: String, Codable, Sendable {
            case systemConsole
            case log
            case silent
            case service
        }
    }

    /// One GPU profile's bootconfig fragment (§4.7).
    public struct GPUProfile: Codable, Equatable, Sendable {
        /// The bootconfig layer-2 keys this profile adds.
        public var bootconfig: [String: String]
        /// Keys of bootconfig.txt that this profile may override.
        public var overrides: [String]
        /// The virtio-gpu features the host device must offer: `virgl`, `edid`.
        public var requiredHostCapabilities: [String]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case bootconfig, overrides, requiredHostCapabilities
        }
    }

    /// What the host must provide (§4.8).
    public struct Requirements: Codable, Equatable, Sendable {
        /// The oldest APKRun that may boot this image.
        public var minimumRuntimeVersion: String
        /// The guest protocol majors the image's agents speak.
        public var guestProtocol: ProtocolRange
        /// Agents built into the image. Empty for `stock`.
        public var agents: [Agent]

        enum CodingKeys: String, CodingKey, CaseIterable {
            case minimumRuntimeVersion, guestProtocol, agents
        }

        /// An inclusive range of guest protocol majors.
        public struct ProtocolRange: Codable, Equatable, Sendable {
            /// The lowest major.
            public var min: Int
            /// The highest major.
            public var max: Int

            enum CodingKeys: String, CodingKey, CaseIterable { case min, max }
        }

        /// An agent package built into the image.
        public struct Agent: Codable, Equatable, Sendable {
            /// The Android package name.
            public var package: String
            /// The agent's `longVersionCode`.
            public var versionCode: Int64

            enum CodingKeys: String, CodingKey, CaseIterable { case package, versionCode }
        }
    }

    /// Userdata schema compatibility (§4.9).
    public struct Userdata: Codable, Equatable, Sendable {
        /// What `/data` and `/metadata` look like after this image boots them.
        public var schemaVersion: Int
        /// The instance userdata schemas this image can boot.
        public var upgradableFrom: [Int]

        enum CodingKeys: String, CodingKey, CaseIterable { case schemaVersion, upgradableFrom }
    }

    /// Which images may migrate to this one (§4.9).
    public struct Compatibility: Codable, Equatable, Sendable {
        /// The migration source rule.
        public var upgradeFrom: UpgradeFrom

        enum CodingKeys: String, CodingKey, CaseIterable { case upgradeFrom }

        /// The oldest current image that may migrate to this one.
        public struct UpgradeFrom: Codable, Equatable, Sendable {
            /// The oldest migration source, in short form `YYYY.MM.N`.
            public var minimumImageVersion: String

            enum CodingKeys: String, CodingKey, CaseIterable { case minimumImageVersion }
        }
    }

    /// The notices file of a release bundle (§4.2).
    public struct Legal: Codable, Equatable, Sendable {
        /// The `legal/` notice file.
        public var notice: FileEntry

        enum CodingKeys: String, CodingKey, CaseIterable { case notice }
    }

    /// Where the bundle came from (§4.3). Informational apart from S1, S2, S13, and S14.
    public struct Provenance: Codable, Equatable, Sendable {
        /// The Android build and its downloaded archives.
        public var source: Source
        /// Release, SDK, variant, and security patch month.
        public var android: Android
        /// The device family, for example `cuttlefish-phone-arm64`.
        public var deviceFamily: String
        /// The layout file that was used, and its SHA-256.
        public var layout: FileReference
        /// The reference capture that supplied bootconfig values, or nil.
        public var reference: String?
        /// Versions of the tools that built the bundle.
        public var tools: Tools
        /// Git revisions of `Images/tools` and `Guest/`.
        public var revisions: Revisions
        /// SHA-256 of the pinned manifest: required for `apkrun`, null for `stock`.
        public var pinnedManifestSHA256: String?
        /// Digest of the builder container image: required for `apkrun`, null for `stock`.
        public var builderImageDigest: String?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case source, android, deviceFamily, layout, reference, tools, revisions
            case pinnedManifestSHA256, builderImageDigest
        }

        /// A repository-relative file and its SHA-256.
        public struct FileReference: Codable, Equatable, Sendable {
            /// The repository-relative path.
            public var path: String
            /// The SHA-256 in lowercase hex.
            public var sha256: String

            enum CodingKeys: String, CodingKey, CaseIterable { case path, sha256 }
        }

        /// The Android build: where it was published, and its archives.
        public struct Source: Codable, Equatable, Sendable {
            /// `ci.android.com` for stock builds, `apkrun-builder` for the product.
            public var origin: String
            /// The source branch.
            public var branch: String
            /// The build target, for example `aosp_cf_arm64_only_phone-userdebug`.
            public var target: String
            /// The build ID: digits for `ci.android.com`, `ar` plus six digits for the builder.
            public var buildId: String
            /// The downloaded archives.
            public var archives: [Archive]

            enum CodingKeys: String, CodingKey, CaseIterable {
                case origin, branch, target, buildId, archives
            }

            /// One downloaded archive.
            public struct Archive: Codable, Equatable, Sendable {
                /// The file name.
                public var name: String
                /// The size in bytes.
                public var size: UInt64
                /// The SHA-256 in lowercase hex.
                public var sha256: String

                enum CodingKeys: String, CodingKey, CaseIterable { case name, size, sha256 }
            }
        }

        /// The Android release the image was built from.
        public struct Android: Codable, Equatable, Sendable {
            /// The Android release, for example `17`.
            public var release: String
            /// The API level.
            public var sdk: Int
            /// The build variant: `user`, `userdebug`, or `eng`.
            public var variant: String
            /// The security patch month, `YYYY-MM`.
            public var securityPatch: String

            enum CodingKeys: String, CodingKey, CaseIterable { case release, sdk, variant, securityPatch }
        }

        /// Versions of the tools that built the bundle.
        public struct Tools: Codable, Equatable, Sendable {
            /// The `apkrun_image` package version.
            public var apkrunImage: String
            /// The pinned mkbootimg revision.
            public var mkbootimg: String
            /// The pinned avbtool revision.
            public var avbtool: String

            enum CodingKeys: String, CodingKey, CaseIterable { case apkrunImage, mkbootimg, avbtool }
        }

        /// Git revisions. `guest` is null for stock bundles.
        public struct Revisions: Codable, Equatable, Sendable {
            /// The revision of `Images/tools`, with `-dirty` when the tree had changes.
            public var imagesTools: String
            /// The revision of `Guest/`, or null.
            public var guest: String?

            enum CodingKeys: String, CodingKey, CaseIterable { case imagesTools, guest }
        }
    }

    /// Guest facts for package checks before the first boot (§4.3).
    public struct Guest: Codable, Equatable, Sendable {
        /// The guest API level; equals `provenance.android.sdk`.
        public var sdk: Int
        /// The guest ABIs, primary first.
        public var abis: [String]
        /// The lowest target SDK Android installs.
        public var targetSdkFloor: Int

        enum CodingKeys: String, CodingKey, CaseIterable { case sdk, abis, targetSdkFloor }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, imageVersion, kind, provenance, guest, boot, disks, templates
        case consolePorts, gpuProfiles, requirements, userdata, compatibility, legal, files
    }
}

// MARK: - Strict decoders (§11)

extension RuntimeImageManifest {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            imageVersion: try c.decode(ImageVersion.self, forKey: .imageVersion),
            kind: try c.decode(Kind.self, forKey: .kind),
            provenance: try c.decode(Provenance.self, forKey: .provenance),
            guest: try c.decode(Guest.self, forKey: .guest),
            boot: try c.decode(Boot.self, forKey: .boot),
            disks: try c.decode([Disk].self, forKey: .disks),
            templates: try c.decode([Disk].self, forKey: .templates),
            consolePorts: try c.decode([ConsolePort].self, forKey: .consolePorts),
            gpuProfiles: try c.decode([String: GPUProfile].self, forKey: .gpuProfiles),
            requirements: try c.decode(Requirements.self, forKey: .requirements),
            userdata: try c.decode(Userdata.self, forKey: .userdata),
            compatibility: try c.decode(Compatibility.self, forKey: .compatibility),
            // Present with null is a schema failure (the schema forbids null here).
            legal: c.contains(.legal) ? try c.decode(Legal.self, forKey: .legal) : nil,
            files: try c.decode([FileEntry].self, forKey: .files)
        )
    }
}

extension RuntimeImageManifest.FileEntry {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try c.decode(String.self, forKey: .path),
            size: try c.decode(UInt64.self, forKey: .size),
            sha256: try c.decode(String.self, forKey: .sha256)
        )
    }
}

extension RuntimeImageManifest.Boot {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kernel: try c.decode(RuntimeImageManifest.FileEntry.self, forKey: .kernel),
            ramdisk: try c.decode(RuntimeImageManifest.FileEntry.self, forKey: .ramdisk),
            bootconfig: try c.decode(RuntimeImageManifest.FileEntry.self, forKey: .bootconfig),
            cmdline: try c.decode(RuntimeImageManifest.FileEntry.self, forKey: .cmdline),
            kernelPageSize: try c.decode(Int.self, forKey: .kernelPageSize),
            bootconfigOverrides: try c.decode([String].self, forKey: .bootconfigOverrides)
        )
    }
}

extension RuntimeImageManifest.Disk {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            role: try c.decode(String.self, forKey: .role),
            path: try c.decode(String.self, forKey: .path),
            readOnly: try c.decode(Bool.self, forKey: .readOnly),
            identifier: try c.decode(String.self, forKey: .identifier),
            logicalSize: try c.decode(UInt64.self, forKey: .logicalSize),
            // Present with null is a schema failure (the schema forbids null here).
            userdataStrategy: c.contains(.userdataStrategy)
                ? try c.decode(RuntimeImageManifest.UserdataStrategy.self, forKey: .userdataStrategy)
                : nil,
            partitions: try c.decode([Partition].self, forKey: .partitions)
        )
    }
}

extension RuntimeImageManifest.Disk.Partition {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try c.decode(String.self, forKey: .label),
            firstLBA: try c.decode(UInt64.self, forKey: .firstLBA),
            size: try c.decode(UInt64.self, forKey: .size),
            sha256: try c.decode(String.self, forKey: .sha256)
        )
    }
}

extension RuntimeImageManifest.ConsolePort {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            index: try c.decode(Int.self, forKey: .index),
            role: try c.decode(Role.self, forKey: .role),
            name: try c.decode(String.self, forKey: .name)
        )
    }
}

extension RuntimeImageManifest.GPUProfile {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            bootconfig: try c.decode([String: String].self, forKey: .bootconfig),
            overrides: try c.decode([String].self, forKey: .overrides),
            requiredHostCapabilities: try c.decode([String].self, forKey: .requiredHostCapabilities)
        )
    }
}

extension RuntimeImageManifest.Requirements {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            minimumRuntimeVersion: try c.decode(String.self, forKey: .minimumRuntimeVersion),
            guestProtocol: try c.decode(ProtocolRange.self, forKey: .guestProtocol),
            agents: try c.decode([Agent].self, forKey: .agents)
        )
    }
}

extension RuntimeImageManifest.Requirements.ProtocolRange {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            min: try c.decode(Int.self, forKey: .min),
            max: try c.decode(Int.self, forKey: .max)
        )
    }
}

extension RuntimeImageManifest.Requirements.Agent {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            package: try c.decode(String.self, forKey: .package),
            versionCode: try c.decode(Int64.self, forKey: .versionCode)
        )
    }
}

extension RuntimeImageManifest.Userdata {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try c.decode(Int.self, forKey: .schemaVersion),
            upgradableFrom: try c.decode([Int].self, forKey: .upgradableFrom)
        )
    }
}

extension RuntimeImageManifest.Compatibility {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(upgradeFrom: try c.decode(UpgradeFrom.self, forKey: .upgradeFrom))
    }
}

extension RuntimeImageManifest.Compatibility.UpgradeFrom {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(minimumImageVersion: try c.decode(String.self, forKey: .minimumImageVersion))
    }
}

extension RuntimeImageManifest.Legal {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(notice: try c.decode(RuntimeImageManifest.FileEntry.self, forKey: .notice))
    }
}

extension RuntimeImageManifest.Guest {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sdk: try c.decode(Int.self, forKey: .sdk),
            abis: try c.decode([String].self, forKey: .abis),
            targetSdkFloor: try c.decode(Int.self, forKey: .targetSdkFloor)
        )
    }
}

extension RuntimeImageManifest.Provenance {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try c.decode(Source.self, forKey: .source),
            android: try c.decode(Android.self, forKey: .android),
            deviceFamily: try c.decode(String.self, forKey: .deviceFamily),
            layout: try c.decode(FileReference.self, forKey: .layout),
            // Required but nullable: a missing key fails, a null value is nil.
            reference: try c.decode(String?.self, forKey: .reference),
            tools: try c.decode(Tools.self, forKey: .tools),
            revisions: try c.decode(Revisions.self, forKey: .revisions),
            pinnedManifestSHA256: try c.decode(String?.self, forKey: .pinnedManifestSHA256),
            builderImageDigest: try c.decode(String?.self, forKey: .builderImageDigest)
        )
    }

    /// Writes the nullable fields as `null`, as the schema requires.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        try c.encode(android, forKey: .android)
        try c.encode(deviceFamily, forKey: .deviceFamily)
        try c.encode(layout, forKey: .layout)
        try c.encode(reference, forKey: .reference)
        try c.encode(tools, forKey: .tools)
        try c.encode(revisions, forKey: .revisions)
        try c.encode(pinnedManifestSHA256, forKey: .pinnedManifestSHA256)
        try c.encode(builderImageDigest, forKey: .builderImageDigest)
    }
}

extension RuntimeImageManifest.Provenance.FileReference {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try c.decode(String.self, forKey: .path),
            sha256: try c.decode(String.self, forKey: .sha256)
        )
    }
}

extension RuntimeImageManifest.Provenance.Source {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            origin: try c.decode(String.self, forKey: .origin),
            branch: try c.decode(String.self, forKey: .branch),
            target: try c.decode(String.self, forKey: .target),
            buildId: try c.decode(String.self, forKey: .buildId),
            archives: try c.decode([Archive].self, forKey: .archives)
        )
    }
}

extension RuntimeImageManifest.Provenance.Source.Archive {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            size: try c.decode(UInt64.self, forKey: .size),
            sha256: try c.decode(String.self, forKey: .sha256)
        )
    }
}

extension RuntimeImageManifest.Provenance.Android {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            release: try c.decode(String.self, forKey: .release),
            sdk: try c.decode(Int.self, forKey: .sdk),
            variant: try c.decode(String.self, forKey: .variant),
            securityPatch: try c.decode(String.self, forKey: .securityPatch)
        )
    }
}

extension RuntimeImageManifest.Provenance.Tools {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            apkrunImage: try c.decode(String.self, forKey: .apkrunImage),
            mkbootimg: try c.decode(String.self, forKey: .mkbootimg),
            avbtool: try c.decode(String.self, forKey: .avbtool)
        )
    }
}

extension RuntimeImageManifest.Provenance.Revisions {
    /// Decodes the object, rejecting any key the schema does not name (§11).
    public init(from decoder: any Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            imagesTools: try c.decode(String.self, forKey: .imagesTools),
            guest: try c.decode(String?.self, forKey: .guest)
        )
    }

    /// Writes `guest` as `null` for stock bundles, as the schema requires.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(imagesTools, forKey: .imagesTools)
        try c.encode(guest, forKey: .guest)
    }
}

// MARK: - Loading

extension RuntimeImageManifest {
    /// Decodes `manifest.json` bytes and checks the value rules (runtime-image-manifest.md §7.1,
    /// steps 4–6). A newer schema version, malformed JSON, and every rule failure are
    /// `manifestInvalid`, with the rule named in the reason (`schema`, `S1`…`S14`).
    public static func load(_ data: Data) throws(ImageFailure) -> RuntimeImageManifest {
        guard data.count <= ManifestLimits.manifestBytes else {
            throw .manifestInvalid(path: "manifest.json", reason: "schema: larger than 1 MiB")
        }
        if let problem = RuntimeImageManifestJSON.firstProblem(in: data) {
            throw .manifestInvalid(path: "manifest.json", reason: "schema: \(problem)")
        }
        struct Version: Decodable { let schemaVersion: Int }
        if let version = try? JSONDecoder().decode(Version.self, from: data),
            version.schemaVersion > 1
        {
            throw .manifestInvalid(path: "manifest.json", reason: "needs a newer APKRun")
        }
        let manifest: RuntimeImageManifest
        do {
            manifest = try JSONDecoder().decode(RuntimeImageManifest.self, from: data)
        } catch let error as DecodingError {
            let (path, reason) = describe(error)
            throw .manifestInvalid(path: path, reason: "schema: \(reason)")
        } catch {
            throw .manifestInvalid(path: "manifest.json", reason: "schema: does not parse")
        }
        if let violation = RuntimeImageManifestRules.violations(of: manifest).first {
            throw .manifestInvalid(
                path: violation.path, reason: "\(violation.rule): \(violation.reason)"
            )
        }
        return manifest
    }

    private static func describe(_ error: DecodingError) -> (path: String, reason: String) {
        let context: DecodingError.Context
        switch error {
        case .keyNotFound(_, let found):
            context = found
        case .typeMismatch(_, let found), .valueNotFound(_, let found), .dataCorrupted(let found):
            context = found
        @unknown default:
            return ("/", "does not decode")
        }
        let pointer = context.codingPath.map(\.stringValue).joined(separator: "/")
        return ("/" + pointer, context.debugDescription)
    }
}

/// Size limits of `manifest.json` and `manifest.sig` (runtime-image-manifest.md §7.1 step 1).
enum ManifestLimits {
    static let manifestBytes = 1024 * 1024
    static let signatureBytes = 4096
}

/// A coding key for any string, used to read the keys an object actually has.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

extension Decoder {
    /// Rejects any key of this object that is not a case of `Keys` (runtime-image-manifest.md §11).
    func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(_ keys: Keys.Type) throws {
        let container = try self.container(keyedBy: AnyCodingKey.self)
        let known = Set(Keys.allCases.map(\.stringValue))
        if let unknown = container.allKeys.first(where: { !known.contains($0.stringValue) }) {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath + [unknown],
                    debugDescription: "unknown field \(unknown.stringValue)"
                )
            )
        }
    }
}
