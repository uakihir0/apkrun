import Foundation
import VirtioDeviceCore
import Virtualization

enum VZConfigurationBuilder {
    /// The most `VZVirtioConsoleDeviceSerialPortConfiguration`s VZ accepts (vm.md §6.1).
    static let maximumSingleConsolePorts = 10

    static func nullDeviceConsoleAttachments(
        count: Int
    ) throws -> [VZSerialPortAttachment] {
        let nullDeviceURL = URL(fileURLWithPath: "/dev/null")
        return try (0..<count).map { _ in
            let fileHandleForReading = try FileHandle(forReadingFrom: nullDeviceURL)
            let fileHandleForWriting = try FileHandle(forWritingTo: nullDeviceURL)
            return VZFileHandleSerialPortAttachment(
                fileHandleForReading: fileHandleForReading,
                fileHandleForWriting: fileHandleForWriting
            )
        }
    }

    static func build(
        _ definition: VMDefinition,
        consolePortAttachments: [VZSerialPortAttachment]
    ) throws -> VZConfigurationBuildResult {
        guard consolePortAttachments.count == definition.consolePorts.count else {
            throw VZConfigurationBuilderError.consoleAttachmentCountMismatch
        }

        let configuration = VZVirtualMachineConfiguration()
        let platform = VZGenericPlatformConfiguration()
        if let data = definition.machineIdentifier {
            guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
                throw VZConfigurationBuilderError.invalidMachineIdentifier
            }
            platform.machineIdentifier = machineIdentifier
        } else {
            platform.machineIdentifier = VZGenericMachineIdentifier()
        }
        configuration.platform = platform
        configuration.label = definition.label

        let (kernelURL, initialRamdiskURL, commandLine) = definition.boot.kernelConfiguration
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.initialRamdiskURL = initialRamdiskURL
        bootLoader.commandLine = commandLine
        configuration.bootLoader = bootLoader
        configuration.cpuCount = definition.cpuCount
        configuration.memorySize = definition.memorySize

        configuration.storageDevices = try definition.disks.map { disk in
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: disk.url,
                readOnly: disk.readOnly,
                cachingMode: disk.caching.vzValue,
                synchronizationMode: disk.synchronization.vzValue
            )
            let device = VZVirtioBlockDeviceConfiguration(attachment: attachment)
            if let identifier = disk.identifier {
                device.blockDeviceIdentifier = identifier
            }
            return device
        }

        configuration.networkDevices = try definition.networks.map { network in
            guard case .nat(let macAddress) = network, let address = VZMACAddress(string: macAddress)
            else {
                throw VZConfigurationBuilderError.invalidMACAddress
            }
            let device = VZVirtioNetworkDeviceConfiguration()
            device.attachment = VZNATNetworkDeviceAttachment()
            device.macAddress = address
            return device
        }

        configuration.socketDevices =
            definition.vsockEnabled
            ? [VZVirtioSocketDeviceConfiguration()]
            : []
        // Ports 0-9 are single-port devices. Later ports are the console ports of one
        // multiport device, which the guest numbers after them (vm.md §6.1).
        configuration.serialPorts =
            consolePortAttachments
            .prefix(maximumSingleConsolePorts)
            .map { attachment in
                let port = VZVirtioConsoleDeviceSerialPortConfiguration()
                port.attachment = attachment
                return port
            }
        let extraAttachments = consolePortAttachments.dropFirst(maximumSingleConsolePorts)
        if extraAttachments.isEmpty {
            configuration.consoleDevices = []
        } else {
            let console = VZVirtioConsoleDeviceConfiguration()
            for (index, attachment) in extraAttachments.enumerated() {
                let port = VZVirtioConsolePortConfiguration()
                port.isConsole = true
                port.attachment = attachment
                console.ports[index] = port
            }
            configuration.consoleDevices = [console]
        }
        configuration.entropyDevices =
            definition.entropy
            ? [VZVirtioEntropyDeviceConfiguration()]
            : []
        configuration.memoryBalloonDevices =
            definition.memoryBalloon
            ? [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            : []

        if let sound = definition.sound {
            var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
            if sound.output {
                let output = VZVirtioSoundDeviceOutputStreamConfiguration()
                output.sink = VZHostAudioOutputStreamSink()
                streams.append(output)
            }
            if sound.input {
                let input = VZVirtioSoundDeviceInputStreamConfiguration()
                input.source = VZHostAudioInputStreamSource()
                streams.append(input)
            }
            let device = VZVirtioSoundDeviceConfiguration()
            device.streams = streams
            configuration.audioDevices = [device]
        } else {
            configuration.audioDevices = []
        }

        let customDeviceAdapters = try definition.customDevices.enumerated().map { index, model in
            try VZCustomVirtioDeviceAdapter(model: model, index: index)
        }
        configuration.customVirtioDevices = customDeviceAdapters.map(\.configuration)
        if let display = definition.builtInDisplay {
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(
                    widthInPixels: display.widthPixels,
                    heightInPixels: display.heightPixels
                )
            ]
            configuration.graphicsDevices = [graphics]
        } else {
            configuration.graphicsDevices = []
        }
        configuration.keyboards = []
        configuration.pointingDevices = []
        configuration.directorySharingDevices = []
        configuration.usbControllers = []

        return VZConfigurationBuildResult(
            configuration: configuration,
            customDeviceAdapters: customDeviceAdapters
        )
    }
}

struct VZConfigurationBuildResult {
    let configuration: VZVirtualMachineConfiguration
    let customDeviceAdapters: [VZCustomVirtioDeviceAdapter]
}

enum VZConfigurationBuilderError: Error, Equatable {
    case consoleAttachmentCountMismatch
    case invalidMachineIdentifier
    case invalidMACAddress
}

extension BootDefinition {
    fileprivate var kernelConfiguration: (kernelURL: URL, initialRamdiskURL: URL?, commandLine: String) {
        switch self {
        case .linux(let kernel, let initialRamdisk, let commandLine):
            (kernel, initialRamdisk, commandLine)
        }
    }
}

extension DiskCaching {
    fileprivate var vzValue: VZDiskImageCachingMode {
        switch self {
        case .automatic:
            .automatic
        case .cached:
            .cached
        case .uncached:
            .uncached
        }
    }
}

extension DiskSync {
    fileprivate var vzValue: VZDiskImageSynchronizationMode {
        switch self {
        case .full:
            .full
        case .fsync:
            .fsync
        case .none:
            .none
        }
    }
}
