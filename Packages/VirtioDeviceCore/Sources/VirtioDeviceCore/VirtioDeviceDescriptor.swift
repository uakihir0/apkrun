import Foundation

/// Immutable configuration metadata that Virtualization.framework needs to attach a virtio device.
public struct VirtioDeviceDescriptor: Equatable, Sendable {
    /// Stable diagnostic name, such as `virtio-gpu`.
    public var name: String

    /// Virtio device type identifier.
    public var deviceID: UInt16

    /// PCI class code.
    public var pciClass: UInt8

    /// PCI subclass code.
    public var pciSubclass: UInt8

    /// Number of virtqueues exposed by the device.
    public var queueCount: UInt16

    /// Features the guest must negotiate.
    public var mandatoryFeatures: UInt64

    /// Features the guest may negotiate.
    public var optionalFeatures: UInt64

    /// Initial device-specific configuration bytes.
    public var configurationSpace: Data

    /// Guest-visible shared-memory regions.
    public var sharedMemoryRegions: [SharedMemoryRegionDescriptor]

    /// Creates a virtio device descriptor.
    public init(
        name: String,
        deviceID: UInt16,
        pciClass: UInt8,
        pciSubclass: UInt8,
        queueCount: UInt16,
        mandatoryFeatures: UInt64,
        optionalFeatures: UInt64,
        configurationSpace: Data = Data(),
        sharedMemoryRegions: [SharedMemoryRegionDescriptor] = []
    ) {
        self.name = name
        self.deviceID = deviceID
        self.pciClass = pciClass
        self.pciSubclass = pciSubclass
        self.queueCount = queueCount
        self.mandatoryFeatures = mandatoryFeatures
        self.optionalFeatures = optionalFeatures
        self.configurationSpace = configurationSpace
        self.sharedMemoryRegions = sharedMemoryRegions
    }
}
