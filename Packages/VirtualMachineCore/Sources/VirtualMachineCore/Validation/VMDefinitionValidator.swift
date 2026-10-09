import DiagnosticsCore
import Foundation
import Virtualization

/// Validates every VM definition rule and preserves failures in design order.
public struct VMDefinitionValidator: Sendable {
    private let host: any VMHostEnvironment
    private let frameworkValidator: any FrameworkConfigurationValidator
    private let logger: APKLogger?

    /// Creates a validator backed by the current Mac and Virtualization.framework.
    public init() {
        self.init(
            host: LiveVMHostEnvironment(),
            frameworkValidator: VZFrameworkConfigurationValidator(),
            logger: APKLogger(category: VMLogCategory.config)
        )
    }

    package init(
        host: any VMHostEnvironment,
        frameworkValidator: any FrameworkConfigurationValidator,
        logger: APKLogger? = nil
    ) {
        self.host = host
        self.frameworkValidator = frameworkValidator
        self.logger = logger
    }

    /// Returns every validation failure without throwing.
    public func findings(_ definition: VMDefinition) -> [VMConfigurationFailure] {
        collectFindings(in: snapshottingCustomDevices(in: definition))
    }

    /// Validates a definition and returns a value safe to pass to a controller.
    public func validate(
        _ definition: VMDefinition
    ) throws(VMConfigurationFailure) -> ValidatedVMDefinition {
        var validatedDefinition = snapshottingCustomDevices(in: definition)
        if validatedDefinition.machineIdentifier == nil {
            validatedDefinition.machineIdentifier = MachineIdentity.newMachineIdentifier()
        }
        let failures = collectFindings(in: validatedDefinition)
        switch failures.count {
        case 0:
            return ValidatedVMDefinition(
                definition: validatedDefinition,
                validationToken: VMDefinitionValidationToken()
            )
        case 1:
            throw failures[0]
        default:
            throw .configurationInvalid(failures)
        }
    }

    private func collectFindings(in definition: VMDefinition) -> [VMConfigurationFailure] {
        var failures = localFindings(definition)
        if failures.isEmpty,
            let frameworkFailure = frameworkValidator.validate(definition)
        {
            switch frameworkFailure {
            case .customDeviceInvalid(let name, let reason):
                failures.append(
                    .customDeviceInvalid(
                        name: VMDiagnosticToken.sanitize(name),
                        reason: reason
                    )
                )
            case .rejected(let underlying):
                failures.append(.frameworkRejected(underlying: underlying))
            }
        }
        logSummary(for: definition)
        return failures
    }

    private func logSummary(for definition: VMDefinition) {
        guard
            let logger,
            let data = try? JSONEncoder().encode(definition.summary)
        else {
            return
        }
        let summary = String(decoding: data, as: UTF8.self)
        logger.info("VM definition summary: \(summary, .public)")
    }

    private func snapshottingCustomDevices(in definition: VMDefinition) -> VMDefinition {
        var snapshot = definition
        snapshot.customDevices = definition.customDevices.map {
            ValidatedVirtioDeviceModel(underlying: $0)
        }
        return snapshot
    }

    private func localFindings(_ definition: VMDefinition) -> [VMConfigurationFailure] {
        var failures: [VMConfigurationFailure] = []

        let minimumCPUCount = host.minimumAllowedCPUCount
        let maximumCPUCount = min(host.maximumAllowedCPUCount, host.activeProcessorCount)
        let allowedCPUCount =
            maximumCPUCount >= minimumCPUCount
            ? minimumCPUCount...maximumCPUCount
            : nil
        if allowedCPUCount?.contains(definition.cpuCount) != true {
            failures.append(
                .cpuCountOutOfRange(
                    requested: definition.cpuCount,
                    allowed: allowedCPUCount
                )
            )
        }

        let oneMiB: UInt64 = 1_024 * 1_024
        if definition.memorySize % oneMiB != 0
            || definition.memorySize < host.minimumAllowedMemorySize
            || definition.memorySize > host.maximumAllowedMemorySize
        {
            failures.append(.memoryOutOfRange)
        }
        let hostMemoryCap = host.physicalMemoryBytes / 2
        if definition.memorySize > hostMemoryCap {
            failures.append(.memoryExceedsHostCap(cap: hostMemoryCap))
        }

        let (kernelURL, initialRamdiskURL, commandLine) = definition.boot.kernelConfiguration
        let kernelProbe = host.probeFile(at: kernelURL)
        if !kernelProbe.exists || !kernelProbe.isRegularFile || !kernelProbe.isReadable {
            failures.append(.kernelMissing(kernelURL))
        } else {
            let format = KernelImageInspector.inspect(kernelProbe.first64Bytes)
            if format != .arm64Image {
                failures.append(.kernelNotUncompressedImage(detected: format))
            }
        }

        if let initialRamdiskURL {
            let probe = host.probeFile(at: initialRamdiskURL)
            if !probe.exists || !probe.isRegularFile || !probe.isReadable {
                failures.append(.initrdMissing)
            } else if let sizeBytes = probe.sizeBytes {
                if sizeBytes > 512 * 1_024 * 1_024 {
                    failures.append(.initrdTooLarge)
                }
            } else {
                failures.append(.initrdMissing)
            }
        }

        let commandLineBytes = commandLine.utf8
        if commandLineBytes.count > 2_048 || commandLineBytes.contains(where: { $0 > 0x7F }) {
            failures.append(.commandLineInvalid)
        }

        let diskProbes = definition.disks.map { host.probeFile(at: $0.url) }
        for (disk, probe) in zip(definition.disks, diskProbes)
        where !probe.exists || !probe.isRegularFile {
            failures.append(.diskMissing(role: VMDiagnosticToken.sanitize(disk.role)))
        }
        for (disk, probe) in zip(definition.disks, diskProbes)
        where probe.exists && probe.isRegularFile && Self.isAndroidSparse(probe.first64Bytes) {
            failures.append(.diskIsAndroidSparse(role: VMDiagnosticToken.sanitize(disk.role)))
        }
        for (disk, probe) in zip(definition.disks, diskProbes)
        where probe.exists && probe.isRegularFile && !probe.isReadable {
            failures.append(.diskNotReadable(role: VMDiagnosticToken.sanitize(disk.role)))
        }

        var seenDiskURLs: Set<URL> = []
        for (disk, probe) in zip(definition.disks, diskProbes)
        where probe.exists && probe.isRegularFile {
            let resolvedURL =
                probe.resolvedFileURL?.standardizedFileURL
                ?? disk.url.resolvingSymlinksInPath().standardizedFileURL
            if !seenDiskURLs.insert(resolvedURL).inserted {
                failures.append(.duplicateDisk(role: VMDiagnosticToken.sanitize(disk.role)))
            }
        }
        for (disk, probe) in zip(definition.disks, diskProbes)
        where probe.exists && probe.isRegularFile && !disk.readOnly && !probe.isWritable {
            failures.append(.diskNotWritable(role: VMDiagnosticToken.sanitize(disk.role)))
        }
        for disk in definition.disks
        where disk.synchronization == .none && !host.allowsTestOnlyDiskSync {
            failures.append(.diskSyncModeTestOnly(role: VMDiagnosticToken.sanitize(disk.role)))
        }
        for disk in definition.disks {
            if let identifier = disk.identifier,
                identifier.utf8.count > 20 || !identifier.utf8.allSatisfy({ $0 < 0x80 })
            {
                failures.append(.diskIdentifierInvalid)
            }
        }

        if definition.consolePorts.first?.role != .systemConsole {
            failures.append(.missingSystemConsole)
        }

        let macAddresses = definition.networks.map { network in
            switch network {
            case .nat(let macAddress): macAddress
            }
        }
        if macAddresses.contains(where: { !Self.isValidLocallyAdministeredMAC($0) })
            || Set(macAddresses.map { $0.lowercased() }).count != macAddresses.count
        {
            failures.append(.invalidMACAddress)
        }

        if let machineIdentifier = definition.machineIdentifier,
            !Self.isValidMachineIdentifier(machineIdentifier)
        {
            failures.append(.machineIdentifierInvalid)
        }

        for device in definition.customDevices {
            let descriptor = device.descriptor
            if descriptor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append(
                    .customDeviceInvalid(
                        name: VMDiagnosticToken.sanitize(descriptor.name),
                        reason: "name must not be empty"
                    )
                )
            }
            if descriptor.queueCount == 0 {
                failures.append(
                    .customDeviceInvalid(
                        name: VMDiagnosticToken.sanitize(descriptor.name),
                        reason: "queue count must be at least one"
                    )
                )
            }
        }

        if definition.sound?.input == true,
            host.microphoneUsageDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            failures.append(.microphoneUsageDescriptionMissing)
        }

        return failures
    }

    private static func isAndroidSparse(_ bytes: Data) -> Bool {
        bytes.count >= 4 && Array(bytes.prefix(4)) == [0x3A, 0xFF, 0x26, 0xED]
    }

    /// Checks the identifier with a VZ object, which is created on a VM queue.
    private static func isValidMachineIdentifier(_ data: Data) -> Bool {
        VMQueue().performSynchronously {
            VZGenericMachineIdentifier(dataRepresentation: data) != nil
        }
    }

    private static func isValidLocallyAdministeredMAC(_ address: String) -> Bool {
        let bytes = address.utf8
        guard bytes.count == 17 else {
            return false
        }
        for index in 0..<17 {
            if index % 3 == 2 {
                guard bytes[bytes.index(bytes.startIndex, offsetBy: index)] == 0x3A else {
                    return false
                }
            } else {
                let byte = bytes[bytes.index(bytes.startIndex, offsetBy: index)]
                let isDigit = (0x30...0x39).contains(byte)
                let isLowerHex = (0x61...0x66).contains(byte)
                let isUpperHex = (0x41...0x46).contains(byte)
                guard isDigit || isLowerHex || isUpperHex else {
                    return false
                }
            }
        }

        let firstOctetText = String(address.prefix(2))
        guard let firstOctet = UInt8(firstOctetText, radix: 16) else {
            return false
        }
        return firstOctet & 0b0000_0001 == 0 && firstOctet & 0b0000_0010 != 0
    }
}

package struct VMDefinitionValidationToken {
    fileprivate init() {}
}

extension BootDefinition {
    fileprivate var kernelConfiguration: (kernelURL: URL, initialRamdiskURL: URL?, commandLine: String) {
        switch self {
        case .linux(let kernel, let initialRamdisk, let commandLine):
            (kernel, initialRamdisk, commandLine)
        }
    }
}
