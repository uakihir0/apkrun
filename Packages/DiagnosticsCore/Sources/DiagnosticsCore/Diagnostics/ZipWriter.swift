import Compression
import Foundation

/// Streams a ZIP archive into the client's `FileHandle` (diagnostics.md §8.1).
/// Entries are deflated through Compression.framework; the wrapper is written
/// with plain local headers because each entry is fully known before it is
/// emitted, then a central directory and end record.
public final class ZipWriter {
    /// The archive could not be encoded or written.
    public enum Failure: Error {
        /// Compression.framework did not produce a stream.
        case compressionFailed
        /// The output handle rejected a write.
        case writeFailed(Error)
    }

    private struct CentralRecord {
        let name: [UInt8]
        let crc: UInt32
        let compressedSize: UInt32
        let size: UInt32
        let offset: UInt32
        let modificationTime: UInt16
        let modificationDate: UInt16
    }

    private let output: FileHandle
    private var records: [CentralRecord] = []
    private var offset: UInt64 = 0
    private var closed = false

    /// Creates a writer streaming to `output`.
    public init(output: FileHandle) {
        self.output = output
    }

    /// Adds a deflated file entry; names use `/` separators and no drive.
    public func addFile(name: String, data: Data, modificationDate: Date = Date()) throws {
        guard !closed else { return }
        let nameBytes = Array(name.utf8)
        let compressed = try Self.deflate(data)
        let crc = CRC32.checksum(data)
        let (dosTime, dosDate) = Self.dosDateTime(modificationDate)

        var header = Data()
        header.appendLittleEndian(UInt32(0x0403_4B50))  // local file header
        header.appendLittleEndian(UInt16(20))  // version needed
        header.appendLittleEndian(UInt16(1 << 11))  // UTF-8 names
        header.appendLittleEndian(UInt16(8))  // deflate
        header.appendLittleEndian(dosTime)
        header.appendLittleEndian(dosDate)
        header.appendLittleEndian(crc)
        header.appendLittleEndian(UInt32(compressed.count))
        header.appendLittleEndian(UInt32(data.count))
        header.appendLittleEndian(UInt16(nameBytes.count))
        header.appendLittleEndian(UInt16(0))  // extra length
        header.append(contentsOf: nameBytes)

        records.append(
            CentralRecord(
                name: nameBytes,
                crc: crc,
                compressedSize: UInt32(compressed.count),
                size: UInt32(data.count),
                offset: UInt32(offset),
                modificationTime: dosTime,
                modificationDate: dosDate
            ))
        try write(header)
        try write(compressed)
    }

    /// Writes the central directory and the end record.
    public func finish() throws {
        guard !closed else { return }
        closed = true
        let centralOffset = offset
        var central = Data()
        for record in records {
            central.appendLittleEndian(UInt32(0x0201_4B50))
            central.appendLittleEndian(UInt16(20))  // version made by
            central.appendLittleEndian(UInt16(20))  // version needed
            central.appendLittleEndian(UInt16(1 << 11))
            central.appendLittleEndian(UInt16(8))
            central.appendLittleEndian(record.modificationTime)
            central.appendLittleEndian(record.modificationDate)
            central.appendLittleEndian(record.crc)
            central.appendLittleEndian(record.compressedSize)
            central.appendLittleEndian(record.size)
            central.appendLittleEndian(UInt16(record.name.count))
            central.appendLittleEndian(UInt16(0))  // extra
            central.appendLittleEndian(UInt16(0))  // comment
            central.appendLittleEndian(UInt16(0))  // disk
            central.appendLittleEndian(UInt16(0))  // internal attrs
            central.appendLittleEndian(UInt32(0))  // external attrs
            central.appendLittleEndian(record.offset)
            central.append(contentsOf: record.name)
        }
        try write(central)
        var end = Data()
        end.appendLittleEndian(UInt32(0x0605_4B50))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(0))
        end.appendLittleEndian(UInt16(records.count))
        end.appendLittleEndian(UInt16(records.count))
        end.appendLittleEndian(UInt32(central.count))
        end.appendLittleEndian(UInt32(centralOffset))
        end.appendLittleEndian(UInt16(0))
        try write(end)
    }

    private func write(_ data: Data) throws {
        do {
            try output.write(contentsOf: data)
            offset += UInt64(data.count)
        } catch {
            throw Failure.writeFailed(error)
        }
    }

    /// Raw deflate: `COMPRESSION_ZLIB` emits an RFC 1951 stream, which is
    /// exactly what ZIP method 8 stores.
    private static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            // A valid empty deflate stream is a single final stored block.
            return Data([0x03, 0x00])
        }
        let bound = data.count + data.count / 16 + 512
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bound)
        defer { destination.deallocate() }
        let encoded = data.withUnsafeBytes { source -> Int in
            guard let base = source.baseAddress else { return 0 }
            return compression_encode_buffer(
                destination, bound,
                base.assumingMemoryBound(to: UInt8.self), data.count,
                nil, COMPRESSION_ZLIB)
        }
        guard encoded > 0 else { throw Failure.compressionFailed }
        return Data(bytes: destination, count: encoded)
    }

    /// DOS date/time halves of a local or central header.
    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone.current, from: date)
        let year = max(1980, components.year ?? 1980)
        let dosDate = UInt16(
            ((year - 1980) << 9) | ((components.month ?? 1) << 5)
                | (components.day ?? 1))
        let dosTime = UInt16(
            ((components.hour ?? 0) << 11) | ((components.minute ?? 0) << 5)
                | ((components.second ?? 0) / 2))
        return (dosTime, dosDate)
    }
}

/// The polynomial-0xEDB88320 CRC-32 the ZIP format requires.
public enum CRC32 {
    /// The running checksum of `data` (call repeatedly to stream).
    public static func checksum(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var crc = seed ^ 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }
}

extension Data {
    fileprivate mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    fileprivate mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
