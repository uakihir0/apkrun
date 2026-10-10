import Testing
import VirtioDeviceCore
import VirtioDeviceCoreTestSupport

@testable import GraphicsCore

/// Two entries of four bytes each, at separate addresses, holding 0...7.
private func twoEntryBacking() -> (GuestBacking, [FakeGuestMemory]) {
    let first = FakeGuestMemory(
        range: GuestPhysicalRange(address: 0x1000, length: 4),
        bytes: [0, 1, 2, 3]
    )
    let second = FakeGuestMemory(
        range: GuestPhysicalRange(address: 0x2000, length: 4),
        bytes: [4, 5, 6, 7]
    )
    let backing = GuestBacking(
        entries: [
            VirtioGPUMemoryEntry(address: 0x1000, length: 4),
            VirtioGPUMemoryEntry(address: 0x2000, length: 4),
        ],
        views: [first.memory, second.memory]
    )
    return (backing, [first, second])
}

@Test func readGathersAcrossEntries() throws {
    let (backing, _) = twoEntryBacking()
    #expect(backing.totalLength == 8)
    #expect(try backing.read(offset: 2, count: 4) == [2, 3, 4, 5])
    #expect(try backing.read(offset: 0, count: 0) == [])
}

@Test func anAccessOutsideTheBackingFails() {
    let (backing, _) = twoEntryBacking()
    #expect(throws: GuestBackingFailure.outOfBacking) {
        _ = try backing.read(offset: 6, count: 4)
    }
}

@Test func writeScattersAcrossEntries() throws {
    let (backing, memories) = twoEntryBacking()
    try backing.write([9, 9, 9][...], at: 3)
    #expect(try memories[0].memory.copyBytes(at: 0, count: 4) == [0, 1, 2, 9])
    #expect(try memories[1].memory.copyBytes(at: 0, count: 4) == [9, 9, 6, 7])
}

@Test func aBackingInvalidatedByResetFailsAccess() throws {
    let (backing, memories) = twoEntryBacking()
    memories[0].invalidate()
    #expect(throws: GuestBackingFailure.self) {
        _ = try backing.read(offset: 0, count: 4)
    }
}
