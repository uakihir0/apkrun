import Darwin
import Foundation
import Testing

@testable import ImageCore

@Test
func instanceDiskProvisionerClonesGrowsSparseAndRewritesGUIDs() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = try writeTemplate(in: directory)
    let destination = directory.appendingPathComponent("userdata.img")
    let instance = try #require(UUID(uuidString: "3f2504e0-4f89-41d3-9a0c-0305e82c3301"))
    let size: UInt64 = 32 * 1024 * 1024 * 1024
    var provisioner = InstanceDiskProvisioner()
    provisioner.volumeInfo = { url in
        var info = InstanceDiskProvisioner.VolumeInfo.current(for: url)
        info.availableBytes = Int64.max
        return info
    }
    guard InstanceDiskProvisioner.VolumeInfo.current(for: directory).fileSystemType == "apfs" else {
        return  // clonefile needs APFS; the unsupported-volume test covers other volumes.
    }

    try provisioner.provision(
        template: template,
        destination: destination,
        role: "userdata",
        instance: instance,
        growTo: size
    )

    var status = stat()
    #expect(stat(destination.path, &status) == 0)
    #expect(UInt64(status.st_size) == size)
    #expect(Int64(status.st_blocks) * 512 < 16 * 1024 * 1024)
    let descriptor = open(destination.path, O_RDONLY)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let disk = try GPTDisk.read(fileDescriptor: descriptor, diskSize: size)
    #expect(disk.diskGUID == GPTDisk.instanceDiskGUID(instance: instance, role: "userdata"))
    #expect(disk.partitions.map(\.name) == ["misc", "userdata"])
    #expect(disk.partitions.last?.lastLBA == GPTDisk.lastUsableLBA(diskSize: size))
    #expect(
        disk.partitions.first?.uniqueGUID
            == GPTDisk.instancePartitionGUID(instance: instance, role: "userdata", label: "misc")
    )

    let templateDescriptor = open(template.path, O_RDONLY)
    try #require(templateDescriptor >= 0)
    defer { close(templateDescriptor) }
    let untouched = try GPTDisk.read(fileDescriptor: templateDescriptor, diskSize: 3 * 1024 * 1024)
    #expect(untouched.partitions.last?.size == 256 * 1024)
}

@Test
func instanceDiskProvisionerRefusesAVolumeThatIsNotAPFS() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = try writeTemplate(in: directory)
    var provisioner = InstanceDiskProvisioner()
    provisioner.volumeInfo = { _ in
        .init(fileSystemType: "hfs", volumeName: "Legacy", availableBytes: Int64.max)
    }

    #expect(throws: ImageFailure.cloneUnsupported(volume: "Legacy")) {
        try provisioner.provision(
            template: template,
            destination: directory.appendingPathComponent("userdata.img"),
            role: "userdata",
            instance: UUID(),
            growTo: nil
        )
    }
}

@Test
func instanceDiskProvisionerKeepsTheFreeSpaceMargin() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = try writeTemplate(in: directory)
    let growth: UInt64 = 1024 * 1024 * 1024
    var provisioner = InstanceDiskProvisioner()
    provisioner.volumeInfo = { _ in
        .init(fileSystemType: "apfs", volumeName: "Data", availableBytes: 5 * 1024 * 1024 * 1024)
    }

    #expect(
        throws: ImageFailure.insufficientSpace(
            required: Int64(growth) + InstanceDiskProvisioner.freeSpaceMargin,
            available: 5 * 1024 * 1024 * 1024
        )
    ) {
        try provisioner.provision(
            template: template,
            destination: directory.appendingPathComponent("userdata.img"),
            role: "userdata",
            instance: UUID(),
            growTo: 3 * 1024 * 1024 + growth
        )
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("userdata.img").path))
}

@Test
func instanceDiskProvisionerReportsACorruptTemplateAndRemovesTheClone() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = directory.appendingPathComponent("template.img")
    try Data(count: 3 * 1024 * 1024).write(to: template)
    let destination = directory.appendingPathComponent("userdata.img")
    var provisioner = InstanceDiskProvisioner()
    provisioner.volumeInfo = { url in
        var info = InstanceDiskProvisioner.VolumeInfo.current(for: url)
        info.availableBytes = Int64.max
        return info
    }
    guard InstanceDiskProvisioner.VolumeInfo.current(for: directory).fileSystemType == "apfs" else {
        return
    }

    #expect(throws: ImageFailure.instanceCorrupt(reason: "missing protective MBR")) {
        try provisioner.provision(
            template: template,
            destination: destination,
            role: "userdata",
            instance: UUID(),
            growTo: 4 * 1024 * 1024
        )
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-instance-disk-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes the "before" disk of the shared Python GPT fixture as a template.
private func writeTemplate(in directory: URL) throws -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 {
        root.deleteLastPathComponent()
    }
    struct Fixture: Decodable {
        struct Disk: Decodable {
            var size: Int
            var sectors: [String: String]
        }
        var before: Disk
    }
    let fixture = try JSONDecoder().decode(
        Fixture.self,
        from: Data(contentsOf: root.appendingPathComponent("Images/tools/tests/fixtures/gpt/provision.json"))
    )
    var bytes = [UInt8](repeating: 0, count: fixture.before.size)
    for (lba, base64) in fixture.before.sectors {
        let sector = try [UInt8](#require(Data(base64Encoded: base64)))
        let index = try #require(Int(lba)) * 512
        bytes.replaceSubrange(index..<(index + 512), with: sector)
    }
    let url = directory.appendingPathComponent("template.img")
    try Data(bytes).write(to: url)
    return url
}
