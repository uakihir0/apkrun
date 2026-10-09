import Darwin
import Foundation
import Testing

@testable import ImageCore

@Test
func aCloneOfAReadOnlyTemplateIsWritableAndTheTemplateStaysReadOnly() throws {
    let directory = try temporaryFileDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = directory.appendingPathComponent("template.img")
    try Data(repeating: 0x11, count: 8192).write(to: template)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: template.path)

    let instance = directory.appendingPathComponent("instance.img")
    try FileCloner.cloneWritable(template, instance)

    // The clone is writable by its owner and keeps the read bits of the template.
    #expect(permissionBits(instance) & 0o200 != 0)
    #expect(permissionBits(instance) & 0o444 == 0o444)
    let handle = try FileHandle(forWritingTo: instance)
    try handle.seek(toOffset: 0)
    try handle.write(contentsOf: Data(repeating: 0x22, count: 512))
    try handle.close()

    // The write changed the clone only. The template is still read-only and still has its bytes.
    let cloned = try Data(contentsOf: instance)
    let original = try Data(contentsOf: template)
    #expect(cloned.prefix(512).allSatisfy { $0 == 0x22 })
    #expect(original.prefix(512).allSatisfy { $0 == 0x11 })
    #expect(permissionBits(template) & 0o222 == 0)
    #expect(throws: (any Error).self) {
        _ = try FileHandle(forWritingTo: template)
    }
}

@Test
func aPlainCloneKeepsTheReadOnlyModeOfItsSource() throws {
    let directory = try temporaryFileDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let template = directory.appendingPathComponent("template.img")
    try Data(repeating: 0x11, count: 4096).write(to: template)
    try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: template.path)

    // The store clones installed files this way and keeps them read-only (IR-359).
    let installed = directory.appendingPathComponent("installed.img")
    try FileCloner.clone(template, installed)
    #expect(permissionBits(installed) & 0o222 == 0)
}

/// The permission bits of `url`, read without following a link.
private func permissionBits(_ url: URL) -> Int {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        return -1
    }
    return Int(status.st_mode & 0o7777)
}

private func temporaryFileDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("apkrun-file-cloner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
