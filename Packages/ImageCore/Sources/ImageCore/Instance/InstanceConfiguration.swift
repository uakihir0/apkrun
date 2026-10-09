import Foundation

/// `Runtime/instance/instance.json`: the one Android instance (android-image.md §5.1).
public struct InstanceConfiguration: Codable, Equatable, Sendable {
    /// The instance UUID. Disk GUIDs and `androidboot.serialno` derive from it.
    public var instanceID: UUID
    /// The persisted `VZGenericMachineIdentifier` data representation.
    public var machineIdentifier: Data
    /// Locally administered MACs of the mobile and ethernet NICs (§7.4). The
    /// `virt_wifi` NIC's MAC derives from `androidboot.wifi_mac_prefix` instead.
    public var macAddresses: [String]
    /// The instance's CPU, memory, and userdata size.
    public var sizing: InstanceSizing
    /// The image the instance was provisioned with or last migrated to.
    public var imageVersion: ImageVersion
    /// The userdata schema the instance was provisioned with.
    public var userdataSchemaVersion: Int
    /// A new UUID on provisioning, Reset Android, and recovery point restore.
    public var userdataGeneration: UUID
    /// Whether the first-boot settings of android-image.md §7.6 have been applied.
    public var firstBootSettingsApplied: Bool

    /// Creates a value with every field.
    public init(
        instanceID: UUID,
        machineIdentifier: Data,
        macAddresses: [String],
        sizing: InstanceSizing,
        imageVersion: ImageVersion,
        userdataSchemaVersion: Int,
        userdataGeneration: UUID,
        firstBootSettingsApplied: Bool = false
    ) {
        self.instanceID = instanceID
        self.machineIdentifier = machineIdentifier
        self.macAddresses = macAddresses
        self.sizing = sizing
        self.imageVersion = imageVersion
        self.userdataSchemaVersion = userdataSchemaVersion
        self.userdataGeneration = userdataGeneration
        self.firstBootSettingsApplied = firstBootSettingsApplied
    }

    /// `androidboot.serialno`: `APKRUN` and the first 10 hex digits of the instance UUID.
    public var serialNumber: String {
        "APKRUN" + String(instanceID.uuidString.replacingOccurrences(of: "-", with: "").prefix(10)).uppercased()
    }
}

/// CPU, memory, and userdata size of the instance (vm.md §10; android-image.md §5.2).
public struct InstanceSizing: Codable, Equatable, Sendable {
    /// The number of guest vCPUs.
    public var cpuCount: Int
    /// The guest memory size in bytes.
    public var memoryBytes: UInt64
    /// The logical size of the grown `userdata.img`.
    public var userdataBytes: UInt64

    /// 4 vCPU, 4 GiB, and the default 32 GiB of userdata.
    public static let `default` = InstanceSizing(
        cpuCount: 4,
        memoryBytes: 4 * 1024 * 1024 * 1024,
        userdataBytes: 32 * 1024 * 1024 * 1024
    )

    /// Creates a value with every field.
    public init(cpuCount: Int, memoryBytes: UInt64, userdataBytes: UInt64) {
        self.cpuCount = cpuCount
        self.memoryBytes = memoryBytes
        self.userdataBytes = userdataBytes
    }
}
