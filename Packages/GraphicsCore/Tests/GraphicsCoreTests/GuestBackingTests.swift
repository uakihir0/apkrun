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

@Test func manyEntriesAreFoundByOffset() throws {
    // 200 entries of three bytes each; entry k holds the byte k in each of its positions.
    var entries: [VirtioGPUMemoryEntry] = []
    var views: [GuestMemory] = []
    for index in 0..<200 {
        let address = UInt64(0x10_000 + index * 0x1000)
        entries.append(VirtioGPUMemoryEntry(address: address, length: 3))
        let fake = FakeGuestMemory(
            range: GuestPhysicalRange(address: address, length: 3),
            bytes: [UInt8](repeating: UInt8(index), count: 3)
        )
        views.append(fake.memory)
    }
    let backing = GuestBacking(entries: entries, views: views)
    #expect(backing.totalLength == 600)
    // An access that starts in entry 37 and crosses into entry 38.
    #expect(try backing.read(offset: 37 * 3 + 2, count: 4) == [37, 38, 38, 38])
    #expect(try backing.read(offset: 599, count: 1) == [199])
    #expect(try backing.read(offset: 0, count: 0) == [])
    #expect(throws: GuestBackingFailure.outOfBacking) {
        _ = try backing.read(offset: 599, count: 2)
    }
}
