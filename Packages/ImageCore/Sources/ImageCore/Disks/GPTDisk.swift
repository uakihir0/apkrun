import CryptoKit
import Darwin
import Foundation

/// The minimal GPT support ImageCore needs for instance disks (android-image.md §4.4, §5.2).
///
/// It reads and verifies both GPT copies of a raw 512-byte-sector disk and
/// provisions a cloned template: new disk and partition GUIDs derived from the
/// instance UUID, the backup header and entries moved to a new end, and the
/// last partition grown to the new last usable sector. It never creates
/// partitions; `apkrun_image disks` does. The Python `gpt.provision_disk`
/// does the same operation, and both are pinned to the fixtures in
/// `Images/tools/tests/fixtures/gpt/`.
struct GPTDisk: Equatable, Sendable {
    static let sectorSize: UInt64 = 512
    static let entryCount = 128
    static let entrySize = 128
    static let entryArraySectors = UInt64(entryCount * entrySize) / sectorSize
    static let headerSize = 92
    /// The namespace of every APKRun disk and partition GUID (shared with `gpt.py`).
    static let guidNamespace = UUID(
        uuid: (
            0x5D, 0x3F, 0x0B, 0x8E, 0x1C, 0x0A, 0x5B, 0x0E,
            0x9D, 0x43, 0x61, 0x70, 0x6B, 0x72, 0x75, 0x6E
        )
    )

    /// One used entry of the partition array.
    struct Partition: Equatable, Sendable {
        var typeGUID: UUID
        var uniqueGUID: UUID
        var firstLBA: UInt64
        var lastLBA: UInt64
        var attributes: UInt64
        var name: String

        var size: UInt64 { (lastLBA - firstLBA + 1) * GPTDisk.sectorSize }
    }

    var diskSize: UInt64
    var diskGUID: UUID
    var firstUsableLBA: UInt64
    var lastUsableLBA: UInt64
    var partitions: [Partition]

    var backupLBA: UInt64 { diskSize / Self.sectorSize - 1 }

    static func lastUsableLBA(diskSize: UInt64) -> UInt64 {
        diskSize / sectorSize - 2 - entryArraySectors
    }

    /// The disk GUID provisioning gives one instance's disk.
    static func instanceDiskGUID(instance: UUID, role: String) -> UUID {
        uuidV5(namespace: guidNamespace, name: "instance/\(instance.uuidString.lowercased())/\(role)")
    }

    /// The partition GUID provisioning gives one instance's partition.
    static func instancePartitionGUID(instance: UUID, role: String, label: String) -> UUID {
        uuidV5(
            namespace: guidNamespace,
            name: "instance/\(instance.uuidString.lowercased())/\(role)/\(label)"
        )
    }

    /// Reads and verifies the protective MBR and both GPT copies.
    static func read(fileDescriptor: Int32, diskSize: UInt64) throws(GPTDiskError) -> GPTDisk {
        guard diskSize % sectorSize == 0, diskSize >= 2 * 1024 * 1024 else {
            throw .invalidDiskSize(diskSize)
        }
        let mbr = try readBytes(fileDescriptor, offset: 0, count: Int(sectorSize))
        guard mbr[510] == 0x55, mbr[511] == 0xAA, mbr[450] == 0xEE else {
            throw .missingProtectiveMBR
        }
        let primary = try Header(
            bytes: readBytes(fileDescriptor, offset: sectorSize, count: Int(sectorSize)),
            expectedLBA: 1
        )
        let entries = try readBytes(
            fileDescriptor,
            offset: primary.entriesLBA * sectorSize,
            count: entryCount * entrySize
        )
        guard CRC32.checksum(entries) == primary.entriesCRC else {
            throw .entryArrayCRCMismatch
        }
        let backupLBA = diskSize / sectorSize - 1
        guard primary.backupLBA == backupLBA else {
            throw .backupNotAtEnd
        }
        let backup = try Header(
            bytes: readBytes(fileDescriptor, offset: backupLBA * sectorSize, count: Int(sectorSize)),
            expectedLBA: backupLBA
        )
        let backupEntries = try readBytes(
            fileDescriptor,
            offset: backup.entriesLBA * sectorSize,
            count: entryCount * entrySize
        )
        guard backupEntries == entries, backup.entriesCRC == primary.entriesCRC,
            backup.diskGUID == primary.diskGUID
        else {
            throw .backupMismatch
        }
        var partitions: [Partition] = []
        for index in 0..<entryCount {
            let entry = Array(entries[(index * entrySize)..<((index + 1) * entrySize)])
            if entry[0..<16].allSatisfy({ $0 == 0 }) {
                continue
            }
            partitions.append(Partition(entry: entry))
        }
        return GPTDisk(
            diskSize: diskSize,
            diskGUID: primary.diskGUID,
            firstUsableLBA: primary.firstUsableLBA,
            lastUsableLBA: primary.lastUsableLBA,
            partitions: partitions
        )
    }

    /// Gives a cloned template its instance GUIDs and grows its last partition.
    ///
    /// The file must already be extended to `newSize`. The old backup header
    /// and entries are zeroed, both copies are rewritten, and the result is
    /// read back and verified.
    @discardableResult
    static func provision(
        fileDescriptor: Int32,
        oldSize: UInt64,
        newSize: UInt64,
        instance: UUID,
        role: String
    ) throws(GPTDiskError) -> GPTDisk {
        guard newSize >= oldSize, newSize % sectorSize == 0 else {
            throw .invalidDiskSize(newSize)
        }
        var disk = try read(fileDescriptor: fileDescriptor, diskSize: oldSize)
        guard !disk.partitions.isEmpty else {
            throw .noPartitions
        }
        for index in disk.partitions.indices {
            disk.partitions[index].uniqueGUID = instancePartitionGUID(
                instance: instance,
                role: role,
                label: disk.partitions[index].name
            )
        }
        disk.diskSize = newSize
        disk.diskGUID = instanceDiskGUID(instance: instance, role: role)
        disk.lastUsableLBA = lastUsableLBA(diskSize: newSize)
        disk.partitions[disk.partitions.count - 1].lastLBA = disk.lastUsableLBA
        if newSize != oldSize {
            let oldBackupEntries = (oldSize / sectorSize - 1 - entryArraySectors) * sectorSize
            try writeBytes(
                fileDescriptor,
                [UInt8](repeating: 0, count: Int((entryArraySectors + 1) * sectorSize)),
                offset: oldBackupEntries
            )
        }
        try disk.writeTables(fileDescriptor: fileDescriptor)
        return try read(fileDescriptor: fileDescriptor, diskSize: newSize)
    }

    private func writeTables(fileDescriptor: Int32) throws(GPTDiskError) {
        let sectorSize = Self.sectorSize
        var entries = [UInt8]()
        entries.reserveCapacity(Self.entryCount * Self.entrySize)
        for partition in partitions {
            entries += partition.encoded()
        }
        entries += [UInt8](repeating: 0, count: Self.entryCount * Self.entrySize - entries.count)
        let entriesCRC = CRC32.checksum(entries)
        let backupEntriesLBA = backupLBA - Self.entryArraySectors
        let primary = Header(
            currentLBA: 1,
            backupLBA: backupLBA,
            firstUsableLBA: firstUsableLBA,
            lastUsableLBA: lastUsableLBA,
            diskGUID: diskGUID,
            entriesLBA: 2,
            entriesCRC: entriesCRC
        )
        var backup = primary
        backup.currentLBA = backupLBA
        backup.backupLBA = 1
        backup.entriesLBA = backupEntriesLBA

        try Self.writeBytes(fileDescriptor, Self.protectiveMBR(totalSectors: diskSize / sectorSize), offset: 0)
        try Self.writeBytes(fileDescriptor, primary.encoded(), offset: sectorSize)
        try Self.writeBytes(fileDescriptor, entries, offset: 2 * sectorSize)
        try Self.writeBytes(fileDescriptor, entries, offset: backupEntriesLBA * sectorSize)
        try Self.writeBytes(fileDescriptor, backup.encoded(), offset: backupLBA * sectorSize)
        guard fsync(fileDescriptor) == 0 else {
            throw .io(errno: errno)
        }
    }

    private static func protectiveMBR(totalSectors: UInt64) -> [UInt8] {
        var mbr = [UInt8](repeating: 0, count: Int(sectorSize))
        let entry: [UInt8] = [0x00, 0x00, 0x02, 0x00, 0xEE, 0xFF, 0xFF, 0xFF]
        mbr.replaceSubrange(446..<454, with: entry)
        mbr.replaceSubrange(454..<458, with: littleEndian(UInt32(1)))
        mbr.replaceSubrange(458..<462, with: littleEndian(UInt32(min(totalSectors - 1, 0xFFFF_FFFF))))
        mbr[510] = 0x55
        mbr[511] = 0xAA
        return mbr
    }

    private static func readBytes(_ fileDescriptor: Int32, offset: UInt64, count: Int) throws(GPTDiskError) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let result = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return pread(fileDescriptor, base + done, count - done, off_t(offset) + off_t(done))
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw .io(errno: errno)
            }
            if result == 0 {
                throw .truncated(offset: offset)
            }
            done += result
        }
        return buffer
    }

    private static func writeBytes(_ fileDescriptor: Int32, _ bytes: [UInt8], offset: UInt64) throws(GPTDiskError) {
        var done = 0
        while done < bytes.count {
            let result = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return pwrite(fileDescriptor, base + done, bytes.count - done, off_t(offset) + off_t(done))
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw .io(errno: errno)
            }
            done += result
        }
    }
}

/// Why a GPT could not be read or provisioned. ImageCore converts it to an `ImageFailure`.
enum GPTDiskError: Error, Equatable, Sendable {
    case invalidDiskSize(UInt64)
    case missingProtectiveMBR
    case invalidHeader(lba: UInt64, reason: String)
    case entryArrayCRCMismatch
    case backupNotAtEnd
    case backupMismatch
    case noPartitions
    case truncated(offset: UInt64)
    case io(errno: Int32)

    /// A short reason for logs and `ImageFailure.instanceCorrupt`.
    var reason: String {
        switch self {
        case .invalidDiskSize(let size): "invalid GPT disk size \(size)"
        case .missingProtectiveMBR: "missing protective MBR"
        case .invalidHeader(let lba, let reason): "GPT header at LBA \(lba): \(reason)"
        case .entryArrayCRCMismatch: "GPT entry array CRC mismatch"
        case .backupNotAtEnd: "the backup GPT header is not at the last sector"
        case .backupMismatch: "the backup GPT does not match the primary GPT"
        case .noPartitions: "the disk has no partition to grow"
        case .truncated(let offset): "disk truncated at offset \(offset)"
        case .io(let errno): "I/O error \(errno)"
        }
    }
}

extension GPTDisk {
    fileprivate struct Header: Equatable {
        var currentLBA: UInt64
        var backupLBA: UInt64
        var firstUsableLBA: UInt64
        var lastUsableLBA: UInt64
        var diskGUID: UUID
        var entriesLBA: UInt64
        var entriesCRC: UInt32

        init(
            currentLBA: UInt64,
            backupLBA: UInt64,
            firstUsableLBA: UInt64,
            lastUsableLBA: UInt64,
            diskGUID: UUID,
            entriesLBA: UInt64,
            entriesCRC: UInt32
        ) {
            self.currentLBA = currentLBA
            self.backupLBA = backupLBA
            self.firstUsableLBA = firstUsableLBA
            self.lastUsableLBA = lastUsableLBA
            self.diskGUID = diskGUID
            self.entriesLBA = entriesLBA
            self.entriesCRC = entriesCRC
        }

        init(bytes: [UInt8], expectedLBA: UInt64) throws(GPTDiskError) {
            guard Array(bytes[0..<8]) == Array("EFI PART".utf8) else {
                throw .invalidHeader(lba: expectedLBA, reason: "no GPT signature")
            }
            guard readLittleEndian32(bytes, at: 12) == UInt32(GPTDisk.headerSize) else {
                throw .invalidHeader(lba: expectedLBA, reason: "unsupported header size")
            }
            var checked = Array(bytes[0..<GPTDisk.headerSize])
            checked.replaceSubrange(16..<20, with: [0, 0, 0, 0])
            guard CRC32.checksum(checked) == readLittleEndian32(bytes, at: 16) else {
                throw .invalidHeader(lba: expectedLBA, reason: "header CRC mismatch")
            }
            guard readLittleEndian64(bytes, at: 24) == expectedLBA else {
                throw .invalidHeader(lba: expectedLBA, reason: "names another LBA as its own")
            }
            guard readLittleEndian32(bytes, at: 80) == UInt32(GPTDisk.entryCount),
                readLittleEndian32(bytes, at: 84) == UInt32(GPTDisk.entrySize)
            else {
                throw .invalidHeader(lba: expectedLBA, reason: "unsupported entry array dimensions")
            }
            self.init(
                currentLBA: expectedLBA,
                backupLBA: readLittleEndian64(bytes, at: 32),
                firstUsableLBA: readLittleEndian64(bytes, at: 40),
                lastUsableLBA: readLittleEndian64(bytes, at: 48),
                diskGUID: uuid(mixedEndian: Array(bytes[56..<72])),
                entriesLBA: readLittleEndian64(bytes, at: 72),
                entriesCRC: readLittleEndian32(bytes, at: 88)
            )
        }

        func encoded() -> [UInt8] {
            var header = Array("EFI PART".utf8)
            header += littleEndian(UInt32(0x0001_0000))
            header += littleEndian(UInt32(GPTDisk.headerSize))
            header += [0, 0, 0, 0]  // CRC, filled in below
            header += [0, 0, 0, 0]
            header += littleEndian(currentLBA)
            header += littleEndian(backupLBA)
            header += littleEndian(firstUsableLBA)
            header += littleEndian(lastUsableLBA)
            header += mixedEndianBytes(diskGUID)
            header += littleEndian(entriesLBA)
            header += littleEndian(UInt32(GPTDisk.entryCount))
            header += littleEndian(UInt32(GPTDisk.entrySize))
            header += littleEndian(entriesCRC)
            header.replaceSubrange(16..<20, with: littleEndian(CRC32.checksum(header)))
            return header + [UInt8](repeating: 0, count: Int(GPTDisk.sectorSize) - header.count)
        }
    }
}

extension GPTDisk.Partition {
    fileprivate init(entry: [UInt8]) {
        let nameBytes = Array(entry[56..<128])
        var units: [UInt16] = []
        for index in stride(from: 0, to: nameBytes.count, by: 2) {
            let unit = UInt16(nameBytes[index]) | UInt16(nameBytes[index + 1]) << 8
            if unit == 0 { break }
            units.append(unit)
        }
        self.init(
            typeGUID: uuid(mixedEndian: Array(entry[0..<16])),
            uniqueGUID: uuid(mixedEndian: Array(entry[16..<32])),
            firstLBA: readLittleEndian64(entry, at: 32),
            lastLBA: readLittleEndian64(entry, at: 40),
            attributes: readLittleEndian64(entry, at: 48),
            name: String(decoding: units, as: UTF16.self)
        )
    }

    fileprivate func encoded() -> [UInt8] {
        var entry = mixedEndianBytes(typeGUID) + mixedEndianBytes(uniqueGUID)
        entry += littleEndian(firstLBA)
        entry += littleEndian(lastLBA)
        entry += littleEndian(attributes)
        var name = [UInt8]()
        for unit in self.name.utf16.prefix(36) {
            name += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
        entry += name + [UInt8](repeating: 0, count: 72 - name.count)
        return entry
    }
}

/// The IEEE CRC-32 that GPT uses (the same polynomial as zlib's `crc32`).
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// A name-based (version 5, SHA-1) UUID, as Python's `uuid.uuid5`.
func uuidV5(namespace: UUID, name: String) -> UUID {
    var input = withUnsafeBytes(of: namespace.uuid) { Array($0) }
    input += Array(name.utf8)
    var bytes = Array(Insecure.SHA1.hash(data: input).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
        uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    )
}

/// GPT stores the first three UUID fields little-endian (Python's `UUID.bytes_le`).
private func mixedEndianBytes(_ value: UUID) -> [UInt8] {
    let bytes = withUnsafeBytes(of: value.uuid) { Array($0) }
    return [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]]
        + Array(bytes[8..<16])
}

private func uuid(mixedEndian bytes: [UInt8]) -> UUID {
    let ordered =
        [bytes[3], bytes[2], bytes[1], bytes[0], bytes[5], bytes[4], bytes[7], bytes[6]]
        + Array(bytes[8..<16])
    return UUID(
        uuid: (
            ordered[0], ordered[1], ordered[2], ordered[3], ordered[4], ordered[5], ordered[6],
            ordered[7], ordered[8], ordered[9], ordered[10], ordered[11], ordered[12], ordered[13],
            ordered[14], ordered[15]
        )
    )
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

private func readLittleEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
}

private func readLittleEndian64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
}
