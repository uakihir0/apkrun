import Foundation
import Testing
import VirtioDeviceCore
import VirtualMachineCoreTestSupport
import Virtualization

@testable import VirtualMachineCore

@Test func vzBuilderPreservesDeviceOrderAndLeavesHostOwnedDevicesEmpty() throws {
    let firstDiskURL = FileManager.default.temporaryDirectory
        .appending(path: "apkrun-vm-builder-\(UUID().uuidString)-os.img")
    let secondDiskURL = FileManager.default.temporaryDirectory
        .appending(path: "apkrun-vm-builder-\(UUID().uuidString)-userdata.img")
    try Data(repeating: 0, count: 512).write(to: firstDiskURL)
    try Data(repeating: 0, count: 512).write(to: secondDiskURL)
    defer {
        try? FileManager.default.removeItem(at: firstDiskURL)
        try? FileManager.default.removeItem(at: secondDiskURL)
    }

    var builder = VMDefinitionBuilder()
    builder.machineIdentifier = MachineIdentity.newMachineIdentifier()
    builder.disks = [
        DiskDefinition(
            url: firstDiskURL,
            readOnly: true,
            identifier: "os-disk",
            role: "os"
        ),
        DiskDefinition(
            url: secondDiskURL,
            readOnly: false,
            caching: .uncached,
            synchronization: .fsync,
            identifier: "userdata-disk",
            role: "userdata"
        ),
    ]
    let macAddress = "02:00:00:00:00:01"
    builder.networks = [.nat(macAddress: macAddress)]
    builder.vsockEnabled = true
    builder.consolePorts = [
        ConsolePortDefinition(role: .systemConsole),
        ConsolePortDefinition(role: .service(name: "test")),
    ]
    builder.sound = SoundDefinition(output: true, input: true)
    let definition = builder.build()
    let attachments = try VZConfigurationBuilder.nullDeviceConsoleAttachments(
        count: definition.consolePorts.count
    )

    let buildResult = try VZConfigurationBuilder.build(
        definition,
        consolePortAttachments: attachments
    )
    let configuration = buildResult.configuration

    #expect(configuration.cpuCount == definition.cpuCount)
    #expect(configuration.memorySize == definition.memorySize)
    #expect(configuration.label == definition.label)
    #expect(configuration.storageDevices.count == 2)
    #expect(
        (configuration.storageDevices[0] as? VZVirtioBlockDeviceConfiguration)?
            .blockDeviceIdentifier == "os-disk"
    )
    #expect(
        (configuration.storageDevices[1] as? VZVirtioBlockDeviceConfiguration)?
            .blockDeviceIdentifier == "userdata-disk"
    )
    let readOnlyAttachment = try #require(
        (configuration.storageDevices[0] as? VZVirtioBlockDeviceConfiguration)?
            .attachment as? VZDiskImageStorageDeviceAttachment
    )
    #expect(readOnlyAttachment.isReadOnly)
    #expect(readOnlyAttachment.cachingMode == .automatic)
    #expect(readOnlyAttachment.synchronizationMode == .full)
    let readWriteAttachment = try #require(
        (configuration.storageDevices[1] as? VZVirtioBlockDeviceConfiguration)?
            .attachment as? VZDiskImageStorageDeviceAttachment
    )
    #expect(!readWriteAttachment.isReadOnly)
    #expect(readWriteAttachment.cachingMode == .uncached)
    #expect(readWriteAttachment.synchronizationMode == .fsync)
    #expect(configuration.networkDevices.count == 1)
    #expect(configuration.networkDevices[0].attachment is VZNATNetworkDeviceAttachment)
    #expect(configuration.networkDevices[0].macAddress.string == macAddress)
    #expect(configuration.socketDevices.count == 1)
    #expect(configuration.socketDevices[0] is VZVirtioSocketDeviceConfiguration)
    #expect(configuration.serialPorts.count == 2)
    #expect(configuration.consoleDevices.isEmpty)
    #expect(configuration.entropyDevices.count == 1)
    #expect(configuration.memoryBalloonDevices.count == 1)
    #expect(configuration.audioDevices.count == 1)
    #expect(
        (configuration.audioDevices[0] as? VZVirtioSoundDeviceConfiguration)?
            .streams.count == 2
    )
    #expect(configuration.customVirtioDevices.isEmpty)
    #expect(configuration.graphicsDevices.isEmpty)
    #expect(configuration.keyboards.isEmpty)
    #expect(configuration.pointingDevices.isEmpty)
    #expect(configuration.directorySharingDevices.isEmpty)
    #expect(configuration.usbControllers.isEmpty)
}

@Test func vzBuilderDoesNotAttachVsockWhenDisabled() throws {
    let definition = VMDefinitionBuilder().build()
    let attachments = try VZConfigurationBuilder.nullDeviceConsoleAttachments(
        count: definition.consolePorts.count
    )

    let result = try VZConfigurationBuilder.build(
        definition,
        consolePortAttachments: attachments
    )

    #expect(result.configuration.socketDevices.isEmpty)
}

@Test func vzBuilderRejectsConsoleAttachmentCountMismatch() {
    let definition = VMDefinitionBuilder().build()

    #expect(throws: VZConfigurationBuilderError.consoleAttachmentCountMismatch) {
        try VZConfigurationBuilder.build(definition, consolePortAttachments: [])
    }
}

@Test func vzBuilderAttachesCustomDevicesAndRetainsTheirAdapters() throws {
    let builder = VMDefinitionBuilder()
    var definition = builder.build()
    definition.customDevices = [
        BuilderVirtioDevice(
            descriptor: VirtioDeviceDescriptor(
                name: "builder-test",
                deviceID: 4,
                pciClass: 0x10,
                pciSubclass: 0,
                queueCount: 1,
                mandatoryFeatures: 0,
                optionalFeatures: 1 << 33
            )
        )
    ]
    let attachments = try VZConfigurationBuilder.nullDeviceConsoleAttachments(
        count: definition.consolePorts.count
    )

    let result = try VZConfigurationBuilder.build(
        definition,
        consolePortAttachments: attachments
    )

    #expect(result.customDeviceAdapters.count == 1)
    #expect(result.configuration.customVirtioDevices.count == 1)
    #expect(result.configuration.customVirtioDevices[0].deviceID == 4)
    #expect(result.configuration.customVirtioDevices[0].pciClassID == 0x10)
    #expect(result.configuration.customVirtioDevices[0].virtioQueueCount == 1)
    #expect(result.configuration.customVirtioDevices[0].supportsSaveRestore == false)
}

private final class BuilderVirtioDevice: VirtioDeviceModel, Sendable {
    let descriptor: VirtioDeviceDescriptor

    init(descriptor: VirtioDeviceDescriptor) {
        self.descriptor = descriptor
    }
}

@Test func vzBuilderPutsConsolePortsBeyondTenOnOneMultiportDevice() throws {
    var builder = VMDefinitionBuilder()
    builder.consolePorts =
        [ConsolePortDefinition(role: .systemConsole)]
        + (1..<20).map { ConsolePortDefinition(role: .silent(name: "port\($0)")) }
    let definition = builder.build()
    let attachments = try VZConfigurationBuilder.nullDeviceConsoleAttachments(count: 20)

    let configuration = try VZConfigurationBuilder.build(
        definition,
        consolePortAttachments: attachments
    ).configuration

    #expect(configuration.serialPorts.count == 10)
    for (index, port) in configuration.serialPorts.enumerated() {
        #expect(port.attachment === attachments[index])
    }
    let console = try #require(
        configuration.consoleDevices.first as? VZVirtioConsoleDeviceConfiguration
    )
    #expect(configuration.consoleDevices.count == 1)
    for index in 0..<10 {
        let port = try #require(console.ports[index])
        #expect(port.isConsole)
        #expect(port.attachment === attachments[10 + index])
    }
}

@Test func vzBuilderAttachesNetworksInOrderAndTheBuiltInDisplay() throws {
    var builder = VMDefinitionBuilder()
    let macAddresses = ["02:00:00:00:00:01", "02:00:00:00:00:02", "02:15:b2:00:00:00"]
    builder.networks = macAddresses.map { .nat(macAddress: $0) }
    builder.builtInDisplay = BuiltInDisplayDefinition(widthPixels: 720, heightPixels: 1280)
    let definition = builder.build()

    let configuration = try VZConfigurationBuilder.build(
        definition,
        consolePortAttachments: VZConfigurationBuilder.nullDeviceConsoleAttachments(count: 1)
    ).configuration

    #expect(configuration.networkDevices.map(\.macAddress.string) == macAddresses)
    let graphics = try #require(
        configuration.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration
    )
    #expect(graphics.scanouts.map(\.widthInPixels) == [720])
    #expect(graphics.scanouts.map(\.heightInPixels) == [1280])
}
