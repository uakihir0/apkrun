import VirtioDeviceCore

/// A failure of a backing access. The device maps it to `ERR_INVALID_PARAMETER`.
enum GuestBackingFailure: Error, Equatable, Sendable {
    /// The access falls outside the entries of the backing.
    case outOfBacking
    /// The guest memory view failed (for example after a reset).
    case guestMemory(VirtioFailure)
}

/// The mapped guest memory of one resource: one `GuestMemory` view per backing entry, in order
/// (graphics.md §4.4). Confined to the device queue, like the views it holds.
final class GuestBacking {
    let entries: [VirtioGPUMemoryEntry]
    private let views: [GuestMemory]
    /// The sum of the entry lengths.
    let totalLength: UInt64

    /// - Parameters:
    ///   - entries: The entries, as the guest attached them.
    ///   - views: One mapped view per entry, of the same length as the entry.
    init(entries: [VirtioGPUMemoryEntry], views: [GuestMemory]) {
        precondition(entries.count == views.count, "Each backing entry has exactly one view.")
        self.entries = entries
        self.views = views
        totalLength = entries.reduce(UInt64(0)) { $0 + UInt64($1.length) }
    }

    /// Copies `count` bytes starting `offset` bytes into the backing.
    func read(offset: UInt64, count: Int) throws(GuestBackingFailure) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        for piece in try pieces(offset: offset, count: count) {
            do throws(VirtioFailure) {
                bytes += try views[piece.entry].copyBytes(at: piece.localOffset, count: piece.count)
            } catch {
                throw .guestMemory(error)
            }
        }
        return bytes
    }

    /// Writes `bytes` starting `offset` bytes into the backing.
    func write(_ bytes: ArraySlice<UInt8>, at offset: UInt64) throws(GuestBackingFailure) {
        var consumed = 0
        for piece in try pieces(offset: offset, count: bytes.count) {
            let start = bytes.index(bytes.startIndex, offsetBy: consumed)
            let end = bytes.index(start, offsetBy: piece.count)
            do throws(VirtioFailure) {
                try views[piece.entry].writeBytes(Array(bytes[start..<end]), at: piece.localOffset)
            } catch {
                throw .guestMemory(error)
            }
            consumed += piece.count
        }
    }

    /// One part of an access, inside one entry.
    private struct Piece {
        let entry: Int
        let localOffset: Int
        let count: Int
    }

    /// Splits an access across the entries. Fails when it is not entirely inside the backing.
    private func pieces(offset: UInt64, count: Int) throws(GuestBackingFailure) -> [Piece] {
        guard count >= 0 else { throw .outOfBacking }
        var result: [Piece] = []
        var position = offset
        var remaining = UInt64(count)
        var entryStart: UInt64 = 0
        for (index, entry) in entries.enumerated() where remaining > 0 {
            let entryEnd = entryStart + UInt64(entry.length)
            if position < entryEnd {
                let take = min(remaining, entryEnd - position)
                result.append(
                    Piece(
                        entry: index,
                        localOffset: Int(position - entryStart),
                        count: Int(take)
                    )
                )
                position += take
                remaining -= take
            }
            entryStart = entryEnd
        }
        guard remaining == 0 else { throw .outOfBacking }
        return result
    }
}
