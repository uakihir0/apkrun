import Foundation
import XCTest

@testable import VirtualMachineCore

/// #011 step 4: the Linux test guest sees the Android disks of android-image.md §4.2 as
/// `disks.json` describes them, and the run records the VZ topology for `boot_devices`.
final class LinuxGuestAndroidDiskLayoutTests: XCTestCase {
    func testAndroidDiskLayout() async throws {
        let disks = try AndroidTestDisks.load()
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-android-disks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runDirectory) }
        let writable = runDirectory.appendingPathComponent(disks.readWrite.file)
        XCTAssertEqual(
            clonefile(disks.url(of: disks.readWrite).path, writable.path, 0),
            0,
            "the writable Android disk must be cloned so the test never changes it"
        )

        let result = try await LinuxGuestHarness.run(
            testCase: self,
            stopBehavior: .guestPowerOff,
            powerOff: true,
            tests: ["parts"],
            blockDisks: .init(readOnly: disks.url(of: disks.readOnly), readWrite: writable)
        )

        let console = String(decoding: result.consoleOutput, as: UTF8.self)
        XCTAssertTrue(console.contains("APKRUN-TEST: parts ok disks=2"))
        // The guest tty writes CRLF, which Swift treats as one Character.
        let lines = console.split(whereSeparator: \.isNewline).map(String.init)
        for (deviceIndex, disk) in [disks.readOnly, disks.readWrite].enumerated() {
            let device = "vd\(Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(deviceIndex))))"
            let diskLine = try XCTUnwrap(lines.first { $0.hasPrefix("APKRUN-DISK \(device) ") })
            XCTAssertTrue(diskLine.contains("sectors=\(disk.logicalSize / 512) "), diskLine)
            XCTAssertTrue(diskLine.contains("logical_block_size=512 "), diskLine)
            XCTAssertTrue(diskLine.contains("/40000000.pci/"), diskLine)
            for (index, partition) in disk.partitions.enumerated() {
                let expected =
                    "APKRUN-PART \(device)\(index + 1) partname=\(partition.label) "
                    + "start=\(partition.firstLBA) sectors=\(partition.size / 512)"
                XCTAssertTrue(lines.contains(expected), "missing \(expected)")
            }
            XCTAssertNil(lines.first { $0.hasPrefix("APKRUN-PART \(device)\(disk.partitions.count + 1) ") })
        }

        let topology =
            lines.filter {
                $0.hasPrefix("APKRUN-DISK ") || $0.hasPrefix("APKRUN-PART ")
                    || $0.hasPrefix("APKRUN-PCI ") || $0.hasPrefix("APKRUN-DT ")
            }
            .joined(separator: "\n") + "\n"
        let attachment = XCTAttachment(string: topology)
        attachment.name = "topology.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        try topology.write(
            to: disks.directory.appendingPathComponent("topology.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}

/// `disks.json` and the disks written by `scripts/build-test-android-disks.sh`.
private struct AndroidTestDisks {
    struct Disk: Decodable {
        struct Partition: Decodable {
            var label: String
            var firstLBA: Int
            var size: Int
        }
        var file: String
        var readOnly: Bool
        var logicalSize: Int
        var partitions: [Partition]
    }

    private struct Document: Decodable {
        var disks: [Disk]
    }

    var directory: URL
    var readOnly: Disk
    var readWrite: Disk

    func url(of disk: Disk) -> URL {
        directory.appendingPathComponent(disk.file)
    }

    static func load() throws -> AndroidTestDisks {
        let artifacts = try LinuxGuestHarness.artifactURLs()
        let directory = artifacts.kernel.deletingLastPathComponent()
            .appendingPathComponent("android-disks", isDirectory: true)
        let metadata = directory.appendingPathComponent("disks.json")
        guard FileManager.default.isReadableFile(atPath: metadata.path) else {
            let message = "Android disks are missing. Run scripts/build-test-android-disks.sh."
            if ProcessInfo.processInfo.environment["APKRUN_CI"] == "1"
                || Bundle.main.object(forInfoDictionaryKey: "APKRUN_CI") as? String == "1"
            {
                XCTFail(message)
            }
            throw XCTSkip(message)
        }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: metadata))
        XCTAssertEqual(document.disks.count, 2, "android-image.md §4.2 plans two disks")
        let readOnly = try XCTUnwrap(document.disks.first { $0.readOnly })
        let readWrite = try XCTUnwrap(document.disks.first { !$0.readOnly })
        return AndroidTestDisks(directory: directory, readOnly: readOnly, readWrite: readWrite)
    }
}
