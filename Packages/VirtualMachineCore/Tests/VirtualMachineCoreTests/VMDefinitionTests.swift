import Foundation
import Testing
import VirtioDeviceCore

@testable import VirtualMachineCore

@Test func definitionSummaryIsCodableAndContainsNoFullPathsOrSecrets() throws {
    let kernelURL = URL(fileURLWithPath: "/private/var/tmp/apkrun/secure/Image")
    let initrdURL = URL(fileURLWithPath: "/private/var/tmp/apkrun/secure/initrd.cpio")
    let diskURL = URL(fileURLWithPath: "/private/var/tmp/apkrun/customer-data.img")
    let machineIdentifier = Data([0x01, 0x02, 0x03, 0x04])
    let macAddress = "02:00:00:00:00:01"
    let definition = VMDefinition(
        label: "private-customer-machine-name",
        cpuCount: 4,
        memorySize: 4 * 1_024 * 1_024 * 1_024,
        machineIdentifier: machineIdentifier,
        boot: .linux(
            kernel: kernelURL,
            initialRamdisk: initrdURL,
            commandLine: "console=hvc0 token=private-command-line"
        ),
        disks: [
            DiskDefinition(
                url: diskURL,
                readOnly: false,
                identifier: "guest-serial",
                role: "userdata"
            )
        ],
        network: .nat(macAddress: macAddress),
        vsockEnabled: true,
        consolePorts: [
            ConsolePortDefinition(role: .systemConsole),
            ConsolePortDefinition(role: .log(name: "logcat")),
        ],
        sound: SoundDefinition(output: true, input: false),
        customDevices: [
            FixtureVirtioDevice(
                descriptor: VirtioDeviceDescriptor(
                    name: "fixture-device",
                    deviceID: 4,
                    pciClass: 0x10,
                    pciSubclass: 0,
                    queueCount: 1,
                    mandatoryFeatures: 0,
                    optionalFeatures: 0,
                    configurationSpace: Data([0xAA]),
                    sharedMemoryRegions: [
                        SharedMemoryRegionDescriptor(regionID: 1, sizeBytes: 4_096)
                    ]
                )
            )
        ]
    )

    let summary = definition.summary
    let encoded = try JSONEncoder().encode(summary)
    let serialized = String(decoding: encoded, as: UTF8.self)
    let decoded = try JSONDecoder().decode(VMDefinitionSummary.self, from: encoded)

    #expect(decoded == summary)
    #expect(summary.hasMachineIdentifier)
    #expect(summary.boot.kernelFileName == "Image")
    #expect(summary.boot.initialRamdiskFileName == "initrd.cpio")
    #expect(summary.boot.commandLineByteCount == definitionCommandLineByteCount)
    #expect(summary.disks.map(\.fileName) == ["customer-data.img"])
    #expect(summary.disks.map(\.role) == ["userdata"])
    #expect(summary.consolePorts == [.systemConsole, .log(name: "logcat")])
    #expect(summary.customDeviceNames == ["fixture-device"])
    #expect(serialized.contains("guest-serial") == false)
    #expect(serialized.contains(macAddress) == false)
    #expect(serialized.contains("private-command-line") == false)
    #expect(serialized.contains(machineIdentifier.base64EncodedString()) == false)
    #expect(serialized.contains("/private/var/tmp/apkrun") == false)
    #expect(serialized.contains("private-customer-machine-name") == false)
}

@Test func definitionSummaryRedactsUntrustedDiagnosticTokens() throws {
    let definition = VMDefinition(
        label: "APKRun test",
        cpuCount: 2,
        memorySize: 3 * 1_024 * 1_024 * 1_024,
        boot: .linux(
            kernel: URL(fileURLWithPath: "/private/alice/Image"),
            initialRamdisk: nil,
            commandLine: "console=hvc0"
        ),
        disks: [
            DiskDefinition(
                url: URL(fileURLWithPath: "/private/alice/data.img"),
                readOnly: false,
                role: "/private/alice"
            )
        ],
        consolePorts: [
            ConsolePortDefinition(role: .systemConsole),
            ConsolePortDefinition(role: .service(name: "../private/alice")),
        ],
        customDevices: [
            FixtureVirtioDevice(
                descriptor: VirtioDeviceDescriptor(
                    name: "private/alice",
                    deviceID: 4,
                    pciClass: 0x10,
                    pciSubclass: 0,
                    queueCount: 1,
                    mandatoryFeatures: 0,
                    optionalFeatures: 0
                )
            )
        ]
    )

    let summary = definition.summary
    let serialized = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)

    #expect(summary.disks.first?.role == "redacted")
    #expect(summary.consolePorts == [.systemConsole, .service(name: "redacted")])
    #expect(summary.customDeviceNames == ["redacted"])
    #expect(!serialized.contains("/private/alice"))
}

@Test func definitionUsesDocumentedDeviceDefaults() {
    let definition = VMDefinition(
        label: "APKRun test",
        cpuCount: 2,
        memorySize: 3 * 1_024 * 1_024 * 1_024,
        boot: .linux(
            kernel: URL(fileURLWithPath: "/tmp/Image"),
            initialRamdisk: nil,
            commandLine: ""
        ),
        disks: [],
        consolePorts: [ConsolePortDefinition(role: .systemConsole)]
    )

    #expect(definition.entropy)
    #expect(definition.memoryBalloon)
    #expect(!definition.vsockEnabled)
    #expect(definition.network == nil)
    #expect(definition.sound == nil)
    #expect(definition.customDevices.isEmpty)
    #expect(DiskDefinition(url: URL(fileURLWithPath: "/tmp/os.img"), readOnly: true, role: "os").caching == .automatic)
    #expect(
        DiskDefinition(url: URL(fileURLWithPath: "/tmp/os.img"), readOnly: true, role: "os").synchronization == .full)
}

@Test func diskDefinitionCodableRoundTripsItsConfiguration() throws {
    let disk = DiskDefinition(
        url: URL(fileURLWithPath: "/tmp/disk.img"),
        readOnly: false,
        caching: .uncached,
        synchronization: .fsync,
        identifier: "disk-one",
        role: "persistent"
    )
    let encoded = try JSONEncoder().encode(disk)
    let decoded = try JSONDecoder().decode(DiskDefinition.self, from: encoded)

    #expect(decoded == disk)
}

private let definitionCommandLineByteCount = "console=hvc0 token=private-command-line".utf8.count

private final class FixtureVirtioDevice: VirtioDeviceModel, Sendable {
    let descriptor: VirtioDeviceDescriptor

    init(descriptor: VirtioDeviceDescriptor) {
        self.descriptor = descriptor
    }
}
