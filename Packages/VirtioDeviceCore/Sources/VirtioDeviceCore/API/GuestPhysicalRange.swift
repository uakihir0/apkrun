/// A byte range in guest physical memory.
public struct GuestPhysicalRange: Equatable, Hashable, Sendable {
    /// The first guest physical address in the range.
    public let address: UInt64

    /// The number of bytes in the range.
    public let length: UInt64

    /// Creates a guest physical address range.
    public init(address: UInt64, length: UInt64) {
        self.address = address
        self.length = length
    }

    package func validatedEndAddress() throws(VirtioFailure) -> UInt64 {
        guard length > 0 else {
            throw .guestMemoryRangeInvalid
        }
        let (endAddress, overflow) = address.addingReportingOverflow(length)
        guard !overflow else {
            throw .guestMemoryRangeInvalid
        }
        return endAddress
    }
}
