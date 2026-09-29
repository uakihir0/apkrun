import Foundation
import Testing

@testable import VirtualMachineCore

@Test func liveFileProbeRejectsNonFileURLsEvenWhenTheirPathExists() {
    let url = URL(string: "https://example.invalid/etc/hosts")!
    let probe = LiveVMHostEnvironment().probeFile(at: url)

    #expect(!probe.exists)
    #expect(!probe.isRegularFile)
    #expect(probe.sizeBytes == nil)
    #expect(probe.first64Bytes.isEmpty)
    #expect(!probe.isReadable)
    #expect(!probe.isWritable)
    #expect(probe.resolvedFileURL == nil)
}

@Test func liveFileProbeReadsAndChecksPermissionsWithoutModifyingTheFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "apkrun-vm-file-probe-\(UUID().uuidString).bin")
    let contents = Data((0..<80).map { UInt8($0) })
    try contents.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let probe = LiveVMHostEnvironment().probeFile(at: url)

    #expect(probe.exists)
    #expect(probe.isRegularFile)
    #expect(probe.sizeBytes == UInt64(contents.count))
    #expect(probe.first64Bytes == contents.prefix(64))
    #expect(probe.isReadable)
    #expect(probe.isWritable)
    #expect(probe.resolvedFileURL == url.standardizedFileURL)
    #expect(try Data(contentsOf: url) == contents)
}
