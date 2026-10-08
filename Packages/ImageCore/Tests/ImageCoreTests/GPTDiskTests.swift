import Darwin
import Foundation
import Testing

@testable import ImageCore

@Test
func crc32MatchesTheIEEECheckValue() {
    #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    #expect(CRC32.checksum([]) == 0)
}

@Test
func uuidV5MatchesPythonForTheSharedNamespace() {
    // Python: apkrun_image.gpt.partition_guid("2026.10.0", "os", "super") and disk_guid(...).
    #expect(
        uuidV5(namespace: GPTDisk.guidNamespace, name: "2026.10.0/os/super")
            == UUID(uuidString: "e5decce1-cfc4-518c-b0b8-9f208d637f2e")
    )
    #expect(
        uuidV5(namespace: GPTDisk.guidNamespace, name: "2026.10.0/os")
            == UUID(uuidString: "6a5ba8da-fd6c-5252-8a8d-e143d369dc8a")
    )
}

@Test
func gptDiskProvisioningEqualsThePythonFixtureByteForByte() throws {
    let fixture = try ProvisionFixture.load()
    let url = try fixture.writeBeforeDisk()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let descriptor = open(url.path, O_RDWR)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    try #require(ftruncate(descriptor, off_t(fixture.afterSize)) == 0)

    let disk = try GPTDisk.provision(
        fileDescriptor: descriptor,
        oldSize: fixture.beforeSize,
        newSize: fixture.afterSize,
        instance: fixture.instance,
        role: fixture.role
    )

    let bytes = try [UInt8](Data(contentsOf: url))
    #expect(UInt64(bytes.count) == fixture.afterSize)
    for lba in 0..<(bytes.count / 512) {
        let sector = Array(bytes[(lba * 512)..<((lba + 1) * 512)])
        let expected = fixture.afterSectors[lba] ?? [UInt8](repeating: 0, count: 512)
        #expect(sector == expected, "sector \(lba) differs from the Python fixture")
    }
    #expect(disk.partitions.map(\.name) == ["misc", "userdata"])
    #expect(disk.partitions.last?.lastLBA == disk.lastUsableLBA)
    #expect(disk.diskGUID == GPTDisk.instanceDiskGUID(instance: fixture.instance, role: fixture.role))
}

@Test
func gptDiskReadsTheTemplateAndRejectsCorruption() throws {
    let fixture = try ProvisionFixture.load()
    let url = try fixture.writeBeforeDisk()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let descriptor = open(url.path, O_RDWR)
    try #require(descriptor >= 0)
    defer { close(descriptor) }

    let disk = try GPTDisk.read(fileDescriptor: descriptor, diskSize: fixture.beforeSize)
    #expect(disk.partitions.map(\.firstLBA) == [2048, 4096])
    #expect(disk.partitions.map(\.size) == [512 * 1024, 256 * 1024])

    var corrupt: UInt8 = 0xFF
    #expect(pwrite(descriptor, &corrupt, 1, 512 + 40) == 1)
    #expect(throws: GPTDiskError.invalidHeader(lba: 1, reason: "header CRC mismatch")) {
        _ = try GPTDisk.read(fileDescriptor: descriptor, diskSize: fixture.beforeSize)
    }
}

@Test
func gptDiskProvisioningRejectsAShrink() throws {
    let fixture = try ProvisionFixture.load()
    let url = try fixture.writeBeforeDisk()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let descriptor = open(url.path, O_RDWR)
    try #require(descriptor >= 0)
    defer { close(descriptor) }

    #expect(throws: GPTDiskError.invalidDiskSize(fixture.beforeSize - 1024 * 1024)) {
        try GPTDisk.provision(
            fileDescriptor: descriptor,
            oldSize: fixture.beforeSize,
            newSize: fixture.beforeSize - 1024 * 1024,
            instance: fixture.instance,
            role: fixture.role
        )
    }
}

/// `Images/tools/tests/fixtures/gpt/provision.json`, written by `build_gpt_fixture.py`.
private struct ProvisionFixture {
    var instance: UUID
    var role: String
    var beforeSize: UInt64
    var beforeSectors: [Int: [UInt8]]
    var afterSize: UInt64
    var afterSectors: [Int: [UInt8]]

    private struct Document: Decodable {
        struct Disk: Decodable {
            var size: UInt64
            var sectors: [String: String]
        }
        var instance: String
        var role: String
        var before: Disk
        var after: Disk
    }

    static func load() throws -> ProvisionFixture {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        let url = root.appendingPathComponent("Images/tools/tests/fixtures/gpt/provision.json")
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        func sectors(_ disk: Document.Disk) throws -> [Int: [UInt8]] {
            var result: [Int: [UInt8]] = [:]
            for (lba, base64) in disk.sectors {
                result[try #require(Int(lba))] = try [UInt8](#require(Data(base64Encoded: base64)))
            }
            return result
        }
        return ProvisionFixture(
            instance: try #require(UUID(uuidString: document.instance)),
            role: document.role,
            beforeSize: document.before.size,
            beforeSectors: try sectors(document.before),
            afterSize: document.after.size,
            afterSectors: try sectors(document.after)
        )
    }

    func writeBeforeDisk() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-gpt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("template.img")
        var bytes = [UInt8](repeating: 0, count: Int(beforeSize))
        for (lba, sector) in beforeSectors {
            bytes.replaceSubrange((lba * 512)..<((lba + 1) * 512), with: sector)
        }
        try Data(bytes).write(to: url)
        return url
    }
}
