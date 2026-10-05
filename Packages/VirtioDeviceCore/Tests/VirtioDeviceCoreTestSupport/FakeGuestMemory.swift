import Foundation
import VirtioDeviceCore

/// In-memory implementation of guest memory for device-model unit tests.
public final class FakeGuestMemory {
    private let storage: Storage

    /// The public memory view backed by this fake.
    public let memory: GuestMemory

    /// Creates an initialized guest-memory range.
    public init(range: GuestPhysicalRange, bytes: [UInt8]) {
        precondition(range.length == UInt64(bytes.count))
        do {
            _ = try range.validatedEndAddress()
        } catch {
            preconditionFailure("Fake guest memory requires a valid physical range.")
        }
        storage = Storage(bytes: bytes)
        memory = GuestMemory(range: range, storage: storage)
    }

    /// Invalidates all views backed by this fake.
    public func invalidate() {
        storage.invalidate()
    }
}

private final class Storage: GuestMemoryStorage {
    private var bytes: [UInt8]
    private var isValid = true

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var byteCount: Int {
        isValid ? bytes.count : 0
    }

    func validate() throws(VirtioFailure) {
        guard isValid else {
            throw .guestMemoryInvalidated
        }
    }

    func copyBytes(in range: Range<Int>) throws(VirtioFailure) -> [UInt8] {
        try validate()
        return Array(bytes[range])
    }

    func writeBytes(_ newBytes: [UInt8], at offset: Int) throws(VirtioFailure) {
        try validate()
        let end = offset + newBytes.count
        bytes.replaceSubrange(offset..<end, with: newBytes)
    }

    func invalidate() {
        isValid = false
        bytes.removeAll(keepingCapacity: false)
    }
}
