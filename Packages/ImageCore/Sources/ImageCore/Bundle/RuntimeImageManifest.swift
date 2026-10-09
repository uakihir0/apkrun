import Foundation

/// `manifest.json` of a runtime image bundle (runtime-image-manifest.md §4).
///
/// This first cut (#012) decodes strictly the blocks a boot reads: `boot`,
/// `disks`, `templates`, `consolePorts`, `gpuProfiles`, and `files`. The
/// informational blocks are carried as `JSONValue`; #065 adds their schema,
/// the semantic rules S1-S14, and the signature check.
public struct RuntimeImageManifest: Codable, Equatable, Sendable {
    /// The manifest format version (§11).
    public var schemaVersion: Int
    /// The bundle's version; equals its directory name.
    public var imageVersion: ImageVersion
    /// Whether this is a stock development image or the APKRun product.
    public var kind: Kind
    /// Where the bundle came from (§4.3). Not decoded until #065.
    public var provenance: JSONValue
    /// Guest facts for package checks (§4.3). Not decoded until #065.
    public var guest: JSONValue
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
    /// What the host must provide (§4.8). Not decoded until #065.
    public var requirements: JSONValue
    /// Userdata schema compatibility (§4.9).
    public var userdata: JSONValue
    /// Which images may migrate to this one (§4.9). Not decoded until #065.
    public var compatibility: JSONValue
    /// The notices file entry of a release bundle.
    public var legal: JSONValue?
    /// Every bundle file except the metadata files, sorted by path.
    public var files: [FileEntry]

    /// Whether the bundle is a ci.android.com build (development only) or the APKRun product.
    public enum Kind: String, Codable, Sendable {
        case stock
        case apkrun
    }

    /// A bundle file with its size and SHA-256.
    public struct FileEntry: Codable, Equatable, Sendable {
        /// The bundle-relative path.
        public var path: String
        /// The size in bytes.
        public var size: UInt64
        /// The SHA-256 in lowercase hex.
        public var sha256: String
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
        /// The page size from the kernel header.
        public var kernelPageSize: Int
        /// Layer-1 keys that the image layer may override.
        public var bootconfigOverrides: [String]
    }

    /// One raw GPT disk (§4.5).
    public struct Disk: Codable, Equatable, Sendable {
        /// What the disk is for, or the port's default role.
        public var role: String
        /// The bundle-relative path.
        public var path: String
        /// Whether VZ attaches the disk read-only.
        public var readOnly: Bool
        /// The block device identifier for logs.
        public var identifier: String
        /// The disk size in bytes; for userdata, the template size before growth.
        public var logicalSize: UInt64
        /// How the userdata template becomes /data.
        public var userdataStrategy: UserdataStrategy?
        /// The GPT partitions in on-disk order.
        public var partitions: [Partition]

        /// One GPT partition of a disk.
        public struct Partition: Codable, Equatable, Sendable {
            /// The GPT name, seen as /dev/block/by-name/<label>.
            public var label: String
            /// The first sector.
            public var firstLBA: UInt64
            /// The size in bytes.
            public var size: UInt64
            /// The SHA-256 in lowercase hex.
            public var sha256: String
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
        /// What the disk is for, or the port's default role.
        public var role: Role
        /// The role's name, such as logcat.
        public var name: String

        /// The default console role of a port.
        public enum Role: String, Codable, Sendable {
            case systemConsole
            case log
            case silent
            case service
        }
    }

    /// One GPU profile's layer-2 bootconfig fragment (§4.7).
    public struct GPUProfile: Codable, Equatable, Sendable {
        /// The bootconfig layers 1 and 2, or this profile's layer-2 keys.
        public var bootconfig: [String: String]
        /// Keys of bootconfig.txt that this profile may override.
        public var overrides: [String]
        /// The virtio-gpu features the host device must offer.
        public var requiredHostCapabilities: [String]
    }
}
