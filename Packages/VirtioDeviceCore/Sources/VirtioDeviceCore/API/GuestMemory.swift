/// A bounds-checked view of a mapped range in guest physical memory.
///
/// This value is confined to the custom device's serial device queue. Its
/// backing mapping is invalidated when the device resets or stops.
public final class GuestMemory {
    package let storage: any GuestMemoryStorage

    /// The guest physical range represented by this view.
    public let range: GuestPhysicalRange

    package init(range: GuestPhysicalRange, storage: any GuestMemoryStorage) {
        self.range = range
        self.storage = storage
    }

    /// The mapped byte count.
    public var byteCount: Int {
        storage.byteCount
    }

    /// Copies bytes from the mapped guest range.
    public func copyBytes(at offset: Int, count: Int) throws(VirtioFailure) -> [UInt8] {
        try storage.validate()
        let range = try checkedRange(offset: offset, length: count)
        return try storage.copyBytes(in: range)
    }

    /// Writes bytes into the mapped guest range.
    public func writeBytes(_ bytes: [UInt8], at offset: Int) throws(VirtioFailure) {
        try storage.validate()
        let range = try checkedRange(offset: offset, length: bytes.count)
        try storage.writeBytes(bytes, at: range.lowerBound)
    }

    /// The host memory of the whole mapped range. It is the guest's RAM, not a copy, so writes through it reach
    /// the guest.
    ///
    /// The pointer stays valid only while this view is valid, which ends when the device resets or stops. A
    /// consumer that keeps the pointer longer, such as a renderer that reads the pages after the request returns,
    /// must release it before then. Take the pointer on the device queue.
    public func hostMemory() throws(VirtioFailure) -> UnsafeMutableRawBufferPointer {
        try storage.hostMemory()
    }

    private func checkedRange(offset: Int, length: Int) throws(VirtioFailure) -> Range<Int> {
        try storage.validate()
        let capacity = storage.byteCount
        let (end, overflow) = offset.addingReportingOverflow(length)
        guard offset >= 0, length >= 0, !overflow, end <= capacity else {
            throw .guestMemoryAccessOutOfBounds(
                offset: offset,
                length: length,
                capacity: capacity
            )
        }
        return offset..<end
    }
}

package protocol GuestMemoryStorage: AnyObject {
    var byteCount: Int { get }
    func validate() throws(VirtioFailure)
    func copyBytes(in range: Range<Int>) throws(VirtioFailure) -> [UInt8]
    func writeBytes(_ bytes: [UInt8], at offset: Int) throws(VirtioFailure)
    /// The whole mapped range. Validates the storage first.
    func hostMemory() throws(VirtioFailure) -> UnsafeMutableRawBufferPointer
    func invalidate()
}
