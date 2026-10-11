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
    /// The bytes live in a fixed allocation, so a host pointer keeps its address until the fake is released.
    private let base: UnsafeMutableRawPointer
    private let count: Int
    private var isValid = true

    init(bytes: [UInt8]) {
        count = bytes.count
        base = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
        bytes.withUnsafeBytes { source in
            if let sourceBase = source.baseAddress {
                base.copyMemory(from: sourceBase, byteCount: source.count)
            }
        }
    }

    deinit {
        base.deallocate()
    }

    var byteCount: Int {
        isValid ? count : 0
    }

    func validate() throws(VirtioFailure) {
        guard isValid else {
            throw .guestMemoryInvalidated
        }
    }

    func copyBytes(in range: Range<Int>) throws(VirtioFailure) -> [UInt8] {
        try validate()
        return Array(UnsafeRawBufferPointer(start: base.advanced(by: range.lowerBound), count: range.count))
    }

    func writeBytes(_ newBytes: [UInt8], at offset: Int) throws(VirtioFailure) {
        try validate()
        newBytes.withUnsafeBytes { source in
            if let sourceBase = source.baseAddress {
                base.advanced(by: offset).copyMemory(from: sourceBase, byteCount: source.count)
            }
        }
    }

    func hostMemory() throws(VirtioFailure) -> UnsafeMutableRawBufferPointer {
        try validate()
        return UnsafeMutableRawBufferPointer(start: base, count: count)
    }

    func invalidate() {
        isValid = false
    }
}
