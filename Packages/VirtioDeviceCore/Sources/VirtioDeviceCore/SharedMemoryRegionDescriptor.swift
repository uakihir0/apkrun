/// Describes one guest-visible shared-memory region for a custom virtio device.
public struct SharedMemoryRegionDescriptor: Equatable, Sendable {
    /// Device-specific identifier advertised to the guest.
    public var regionID: UInt8

    /// Size of the shared region in bytes.
    public var sizeBytes: UInt64

    /// Creates a shared-memory region descriptor.
    public init(regionID: UInt8, sizeBytes: UInt64) {
        self.regionID = regionID
        self.sizeBytes = sizeBytes
    }
}
