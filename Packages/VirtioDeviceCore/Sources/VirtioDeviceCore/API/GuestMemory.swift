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
    func invalidate()
}
