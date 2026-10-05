import Darwin
import Foundation
import Testing
import VirtualMachineCoreTestSupport

@testable import VirtualMachineCore

@Test func diskValidationRejectsMissingDirectoriesAndDanglingLinks() throws {
    let files = try DiskValidationFiles()
    let missing = files.url("missing.img")
    let directory = files.url("directory.img")
    let danglingLink = files.url("dangling.img")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
    )
    try FileManager.default.createSymbolicLink(
        at: danglingLink,
        withDestinationURL: files.url("missing-target.img")
    )

    #expect(files.findings(for: missing, role: "missing") == [.diskMissing(role: "missing")])
    #expect(
        files.findings(for: directory, role: "directory") == [
            .diskMissing(role: "directory")
        ]
    )
    #expect(
        files.findings(for: danglingLink, role: "dangling") == [
            .diskMissing(role: "dangling")
        ]
    )
}

@Test func diskValidationRecognizesTheAndroidSparseMagicInARealFile() throws {
    let files = try DiskValidationFiles()
    let image = try files.write("sparse.img", bytes: Data(repeating: 0, count: 64))
    try Data([0x3A, 0xFF, 0x26, 0xED]).write(to: image)

    #expect(files.findings(for: image, role: "sparse") == [.diskIsAndroidSparse(role: "sparse")])
}

@Test func diskValidationFindsDuplicatesAfterResolvingARealSymlink() throws {
    let files = try DiskValidationFiles()
    let image = try files.write("disk.img", bytes: Data(repeating: 0x41, count: 512))
    let alias = files.url("disk-alias.img")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: image)

    #expect(
        files.findings(
            for: [
                DiskDefinition(url: image, readOnly: false, role: "first"),
                DiskDefinition(url: alias, readOnly: false, role: "alias"),
            ]
        ) == [.duplicateDisk(role: "alias")]
    )
}

@Test func diskValidationUsesProcessPermissionsForReadWriteAndReadOnlyDisks() throws {
    let files = try DiskValidationFiles()
    let image = try files.write("readonly.img", bytes: Data(repeating: 0x42, count: 512))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o444],
        ofItemAtPath: image.path
    )

    #expect(files.findings(for: image, readOnly: false, role: "rw") == [.diskNotWritable(role: "rw")])
    #expect(files.findings(for: image, readOnly: true, role: "ro").isEmpty)
}

@Test func diskValidationRejectsAFileWithNoReadPermissionsUnderANonRootUser() throws {
    #expect(geteuid() != 0, "Disk permission system tests must run as a non-root user.")
    let files = try DiskValidationFiles()
    let image = try files.write("unreadable.img", bytes: Data(repeating: 0x43, count: 512))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o000],
        ofItemAtPath: image.path
    )

    #expect(
        files.findings(for: image, readOnly: true, role: "unreadable") == [
            .diskNotReadable(role: "unreadable")
        ])
}

@Test func diskValidationRejectsIdentifiersLongerThanTwentyASCIICharacters() throws {
    let files = try DiskValidationFiles()
    let image = try files.write("identifier.img", bytes: Data(repeating: 0x44, count: 512))
    let disk = DiskDefinition(
        url: image,
        readOnly: true,
        identifier: String(repeating: "x", count: 21),
        role: "identifier"
    )

    #expect(files.findings(for: [disk]) == [.diskIdentifierInvalid])
}

private final class DiskValidationFiles {
    private let directory: URL
    private let kernel: URL
    private let validator: VMDefinitionValidator

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apkrun-disk-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        kernel = directory.appendingPathComponent("Image")
        var header = Data(repeating: 0, count: 64)
        header.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
        try header.write(to: kernel)
        validator = VMDefinitionValidator(
            host: LiveVMHostEnvironment(),
            frameworkValidator: FakeFrameworkConfigurationValidator()
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func url(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    func write(_ name: String, bytes: Data) throws -> URL {
        let file = url(name)
        try bytes.write(to: file)
        return file
    }

    func findings(
        for url: URL,
        readOnly: Bool = false,
        role: String
    ) -> [VMConfigurationFailure] {
        findings(for: [DiskDefinition(url: url, readOnly: readOnly, role: role)])
    }

    func findings(for disks: [DiskDefinition]) -> [VMConfigurationFailure] {
        var definition = VMDefinition(
            label: "disk validation test",
            cpuCount: 2,
            memorySize: 3 * 1_024 * 1_024 * 1_024,
            boot: .linux(kernel: kernel, initialRamdisk: nil, commandLine: "console=hvc0"),
            disks: disks,
            consolePorts: [ConsolePortDefinition(role: .systemConsole)]
        )
        definition.machineIdentifier = MachineIdentity.newMachineIdentifier()
        return validator.findings(definition)
    }
}
