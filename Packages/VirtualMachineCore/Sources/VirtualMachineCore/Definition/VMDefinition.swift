import Foundation
import VirtioDeviceCore

/// A platform-neutral description of one Linux virtual machine.
public struct VMDefinition: Sendable {
    /// Human-readable label passed to Virtualization.framework.
    public var label: String

    /// Number of guest virtual CPUs.
    public var cpuCount: Int

    /// Guest memory size in bytes.
    public var memorySize: UInt64

    /// Persisted Virtualization.framework machine identity, or `nil` to create one.
    public var machineIdentifier: Data?

    /// Linux kernel, initrd, and command line.
    public var boot: BootDefinition

    /// Attached disk images, in guest device order.
    public var disks: [DiskDefinition]

    /// NAT network adapters in guest device order (`eth0`, `eth1`, …).
    public var networks: [NetworkDefinition]

    /// Whether to attach the VM's virtio-vsock device.
    public var vsockEnabled: Bool

    /// Serial ports in guest device order. Port zero must be the system console.
    public var consolePorts: [ConsolePortDefinition]

    /// Whether to attach the built-in virtio entropy device.
    public var entropy: Bool

    /// Whether to attach the built-in memory balloon device.
    public var memoryBalloon: Bool

    /// Optional virtio sound device configuration.
    public var sound: SoundDefinition?

    /// Custom virtio devices supplied by their owning modules.
    public var customDevices: [any VirtioDeviceModel]

    /// VZ's own 2D virtio-gpu, for the development-only Android `headless` profile.
    ///
    /// The stock Android image cannot boot without a DRM device (android-image.md §9.1).
    /// Never set together with a GraphicsCore virtio-gpu device or in a release bundle.
    public var builtInDisplay: BuiltInDisplayDefinition?

    /// A path-reduced, device-free projection suitable for diagnostics and logs.
    public var summary: VMDefinitionSummary {
        VMDefinitionSummary(definition: self)
    }

    /// Creates a VM definition with the documented device defaults.
    public init(
        label: String,
        cpuCount: Int,
        memorySize: UInt64,
        machineIdentifier: Data? = nil,
        boot: BootDefinition,
        disks: [DiskDefinition],
        networks: [NetworkDefinition] = [],
        vsockEnabled: Bool = false,
        consolePorts: [ConsolePortDefinition],
        entropy: Bool = true,
        memoryBalloon: Bool = true,
        sound: SoundDefinition? = nil,
        customDevices: [any VirtioDeviceModel] = [],
        builtInDisplay: BuiltInDisplayDefinition? = nil
    ) {
        self.label = label
        self.cpuCount = cpuCount
        self.memorySize = memorySize
        self.machineIdentifier = machineIdentifier
        self.boot = boot
        self.disks = disks
        self.networks = networks
        self.vsockEnabled = vsockEnabled
        self.consolePorts = consolePorts
        self.entropy = entropy
        self.memoryBalloon = memoryBalloon
        self.sound = sound
        self.customDevices = customDevices
        self.builtInDisplay = builtInDisplay
    }
}

/// Linux boot inputs for a VM.
public enum BootDefinition: Sendable {
    /// Boots a kernel directly with an optional initrd.
    case linux(kernel: URL, initialRamdisk: URL?, commandLine: String)
}

/// Disk image attachment settings.
public struct DiskDefinition: Codable, Equatable, Sendable {
    /// Disk image location.
    public var url: URL

    /// Whether the guest receives a read-only disk.
    public var readOnly: Bool

    /// Virtualization.framework disk caching mode.
    public var caching: DiskCaching

    /// Virtualization.framework disk synchronization mode.
    public var synchronization: DiskSync

    /// Optional guest-visible block-device identifier.
    public var identifier: String?

    /// Stable diagnostic role, such as `os` or `userdata`.
    public var role: String

    /// Creates a disk definition.
    public init(
        url: URL,
        readOnly: Bool,
        caching: DiskCaching = .automatic,
        synchronization: DiskSync = .full,
        identifier: String? = nil,
        role: String
    ) {
        self.url = url
        self.readOnly = readOnly
        self.caching = caching
        self.synchronization = synchronization
        self.identifier = identifier
        self.role = role
    }
}

/// Caching behavior for a virtual disk attachment.
public enum DiskCaching: String, Codable, Equatable, Sendable {
    /// Use Virtualization.framework's default policy.
    case automatic

    /// Cache disk contents.
    case cached

    /// Do not cache disk contents.
    case uncached
}

/// Write synchronization behavior for a virtual disk attachment.
public enum DiskSync: String, Codable, Equatable, Sendable {
    /// Fully synchronize writes; the default for read-write disks.
    case full

    /// Synchronize writes with `fsync`.
    case fsync

    /// Do not synchronize writes. Use only in tests.
    case none
}

/// Network adapter settings.
public enum NetworkDefinition: Codable, Equatable, Sendable {
    /// Attach a NAT network with the persisted locally administered MAC address.
    case nat(macAddress: String)
}

/// A serial console port and its host-side role.
public struct ConsolePortDefinition: Codable, Equatable, Sendable {
    /// The purpose of this guest serial port.
    public var role: ConsoleRole

    /// Creates a console port definition.
    public init(role: ConsoleRole) {
        self.role = role
    }
}

/// The host-side role assigned to a guest serial port.
public enum ConsoleRole: Codable, Equatable, Sendable {
    /// The guest's primary system console.
    case systemConsole

    /// A port whose guest output is written to a named log.
    case log(name: String)

    /// A port whose guest output is discarded.
    case silent(name: String)

    /// A port connected to a host-side service.
    case service(name: String)
}

/// The single scanout of VZ's built-in 2D virtio-gpu (development only).
public struct BuiltInDisplayDefinition: Codable, Equatable, Sendable {
    /// Scanout width in pixels.
    public var widthPixels: Int

    /// Scanout height in pixels.
    public var heightPixels: Int

    /// Creates a built-in display definition.
    public init(widthPixels: Int, heightPixels: Int) {
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }
}

/// Audio stream selection for a virtio sound device.
public struct SoundDefinition: Codable, Equatable, Sendable {
    /// Whether to expose host audio output to the guest.
    public var output: Bool

    /// Whether to expose host microphone input to the guest.
    public var input: Bool

    /// Creates a sound configuration.
    public init(output: Bool, input: Bool) {
        self.output = output
        self.input = input
    }
}
