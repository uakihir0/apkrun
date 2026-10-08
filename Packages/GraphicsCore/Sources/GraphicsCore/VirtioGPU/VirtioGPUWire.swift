/// Little-endian readers and writers for virtio-gpu wire structures.
///
/// Callers check the total byte count before reading. Values are copied out of
/// the request buffer one field at a time; guest memory is never reinterpreted
/// as a struct ([graphics.md](../../../../../docs/02-design/graphics.md) §4.2).
struct VirtioGPUWireReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remainingByteCount: Int {
        bytes.count - offset
    }

    mutating func readUInt8() -> UInt8 {
        UInt8(truncatingIfNeeded: readUnsigned(byteCount: 1))
    }

    mutating func readUInt32() -> UInt32 {
        UInt32(truncatingIfNeeded: readUnsigned(byteCount: 4))
    }

    mutating func readUInt64() -> UInt64 {
        readUnsigned(byteCount: 8)
    }

    mutating func readRect() -> VirtioGPURect {
        VirtioGPURect(
            x: readUInt32(),
            y: readUInt32(),
            width: readUInt32(),
            height: readUInt32()
        )
    }

    mutating func readBytes(count: Int) -> [UInt8] {
        let slice = Array(bytes[offset..<(offset + count)])
        offset += count
        return slice
    }

    mutating func skip(byteCount: Int) {
        offset += byteCount
    }

    private mutating func readUnsigned(byteCount: Int) -> UInt64 {
        precondition(byteCount <= 8 && byteCount <= remainingByteCount)
        var value: UInt64 = 0
        for index in 0..<byteCount {
            value |= UInt64(bytes[offset + index]) << (8 * index)
        }
        offset += byteCount
        return value
    }
}

/// Builds little-endian wire bytes in the order the virtio-gpu structures define them.
struct VirtioGPUWireWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeUInt32(_ value: UInt32) {
        writeUnsigned(UInt64(value), byteCount: 4)
    }

    mutating func writeUInt64(_ value: UInt64) {
        writeUnsigned(value, byteCount: 8)
    }

    mutating func writeRect(_ rect: VirtioGPURect) {
        writeUInt32(rect.x)
        writeUInt32(rect.y)
        writeUInt32(rect.width)
        writeUInt32(rect.height)
    }

    mutating func writeBytes(_ data: [UInt8]) {
        bytes.append(contentsOf: data)
    }

    mutating func writeZeros(count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: count))
    }

    private mutating func writeUnsigned(_ value: UInt64, byteCount: Int) {
        for index in 0..<byteCount {
            bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index)))
        }
    }
}

/// A rectangle in scanout or resource pixels (`virtio_gpu_rect`).
struct VirtioGPURect: Equatable, Sendable {
    var x: UInt32
    var y: UInt32
    var width: UInt32
    var height: UInt32

}
