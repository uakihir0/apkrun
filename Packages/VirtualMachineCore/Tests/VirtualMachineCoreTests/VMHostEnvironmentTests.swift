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

@Test func liveFileProbeResolvesSymlinksAndReadsLargeFiles() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "apkrun-vm-file-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let target = directory.appending(path: "kernel-image")
    let link = directory.appending(path: "kernel-link")
    try Data(repeating: 0, count: 1_048_576).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let probe = LiveVMHostEnvironment().probeFile(at: link)

    #expect(probe.exists)
    #expect(probe.isRegularFile)
    #expect(probe.sizeBytes == 1_048_576)
    #expect(probe.resolvedFileURL == target.standardizedFileURL)
    #expect(probe.isReadable)
    #expect(probe.isWritable)
}
