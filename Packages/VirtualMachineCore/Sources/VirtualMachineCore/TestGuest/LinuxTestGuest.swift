import Foundation
import VirtioDeviceCore

/// Builds the small ARM64 guest used by the M0 VM integration tests.
public enum LinuxTestGuest {
    /// Raw test disks used by the guest's block-device checks.
    public struct BlockDisks: Sendable {
        /// The disk whose bytes must remain unchanged.
        public let readOnly: URL

        /// The disk the guest formats and writes.
        public let readWrite: URL

        /// Creates a pair of test disk image URLs.
        public init(readOnly: URL, readWrite: URL) {
            self.readOnly = readOnly
            self.readWrite = readWrite
        }
    }

    /// Attachment order for the two block-device fixtures.
    public enum BlockDiskOrder: Sendable {
        /// Attach the read-only disk first.
        case readOnlyThenReadWrite

        /// Attach the read-write disk first.
        case readWriteThenReadOnly
    }

    /// Creates the task's two-vCPU, one-GiB Linux test guest definition.
    public static func definition(
        kernel: URL,
        initrd: URL,
        tests: [String] = [],
        blockDisks: BlockDisks? = nil,
        blockDiskOrder: BlockDiskOrder = .readOnlyThenReadWrite,
        customDevices: [any VirtioDeviceModel] = [],
        entropyTestDevice: EntropyTestDevice? = nil,
        powerOff: Bool = false,
        extraCommandLine: [String] = []
    ) -> VMDefinition {
        let checks = tests.joined(separator: ",")
        let runsEntropyTest = tests.contains("rng")
        let usesEntropyDevice = runsEntropyTest || tests.contains("rng-pending")
        let entropyDevice =
            usesEntropyDevice
            ? (entropyTestDevice ?? EntropyTestDevice(seed: 0))
            : nil
        let consolePorts: [ConsolePortDefinition] =
            tests.contains("ports")
            ? [
                ConsolePortDefinition(role: .systemConsole),
                ConsolePortDefinition(role: .service(name: "test-1")),
                ConsolePortDefinition(role: .service(name: "test-2")),
            ]
            : [ConsolePortDefinition(role: .systemConsole)]
        let commandLine =
            ([
                "console=hvc0",
                "apkrun.test=\(checks)",
                "apkrun.test.poweroff=\(powerOff ? 1 : 0)",
            ] + (usesEntropyDevice ? ["rng_core.default_quality=0"] : []) + extraCommandLine)
            .joined(separator: " ")
        let networkDefinition: NetworkDefinition? =
            tests.contains("net")
            ? .nat(macAddress: MachineIdentity.newMACAddress())
            : nil
        let diskDefinitions: [DiskDefinition]
        if let blockDisks {
            let readOnlyDisk = DiskDefinition(
                url: blockDisks.readOnly,
                readOnly: true,
                identifier: "apkrun-ro",
                role: "test-ro"
            )
            let readWriteDisk = DiskDefinition(
                url: blockDisks.readWrite,
                readOnly: false,
                identifier: "apkrun-rw",
                role: "test-rw"
            )
            switch blockDiskOrder {
            case .readOnlyThenReadWrite:
                diskDefinitions = [readOnlyDisk, readWriteDisk]
            case .readWriteThenReadOnly:
                diskDefinitions = [readWriteDisk, readOnlyDisk]
            }
        } else {
            diskDefinitions = []
        }

        return VMDefinition(
            label: "APKRun Linux test guest",
            cpuCount: 2,
            memorySize: 1 * 1_024 * 1_024 * 1_024,
            boot: .linux(
                kernel: kernel,
                initialRamdisk: initrd,
                commandLine: commandLine
            ),
            disks: diskDefinitions,
            network: networkDefinition,
            vsockEnabled: tests.contains("vsock"),
            consolePorts: consolePorts,
            entropy: !usesEntropyDevice,
            customDevices: customDevices + (entropyDevice.map { [$0 as any VirtioDeviceModel] } ?? [])
        )
    }
}
