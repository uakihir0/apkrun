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
    /// The byte offset from the start of the backing at which each entry begins.
    private let starts: [UInt64]
    /// The sum of the entry lengths.
    let totalLength: UInt64

    /// - Parameters:
    ///   - entries: The entries, as the guest attached them.
    ///   - views: One mapped view per entry, of the same length as the entry.
    init(entries: [VirtioGPUMemoryEntry], views: [GuestMemory]) {
        precondition(entries.count == views.count, "Each backing entry has exactly one view.")
        self.entries = entries
        self.views = views
        var starts: [UInt64] = []
        starts.reserveCapacity(entries.count)
        var total: UInt64 = 0
        for entry in entries {
            starts.append(total)
            total += UInt64(entry.length)
        }
        self.starts = starts
        totalLength = total
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

    /// Splits an access across the entries. It takes a binary search to find the first entry, so an access costs
    /// O(log entries) plus its pieces. It fails when the access is not entirely inside the backing.
    private func pieces(offset: UInt64, count: Int) throws(GuestBackingFailure) -> [Piece] {
        guard count >= 0 else { throw .outOfBacking }
        guard count > 0 else { return [] }
        guard offset < totalLength else { throw .outOfBacking }
        guard offset.addingReportingOverflow(UInt64(count)).overflow == false,
            offset + UInt64(count) <= totalLength
        else {
            throw .outOfBacking
        }
        var result: [Piece] = []
        var index = Self.entryIndex(containing: offset, starts: starts)
        var position = offset
        var remaining = UInt64(count)
        while remaining > 0 {
            let entryEnd = starts[index] + UInt64(entries[index].length)
            let take = min(remaining, entryEnd - position)
            result.append(
                Piece(
                    entry: index,
                    localOffset: Int(position - starts[index]),
                    count: Int(take)
                )
            )
            position += take
            remaining -= take
            index += 1
        }
        return result
    }

    /// The index of the entry whose bytes contain `offset`. Callers ensure `offset` is inside the backing.
    private static func entryIndex(containing offset: UInt64, starts: [UInt64]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }
}
