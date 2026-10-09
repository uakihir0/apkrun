import Foundation
import VirtioDeviceCore
import VirtualMachineCore

/// Builds predictable VM definitions for unit and system tests.
package struct VMDefinitionBuilder {
    package var label = "APKRun test VM"
    package var cpuCount = 2
    package var memorySize: UInt64 = 3 * 1_024 * 1_024 * 1_024
    package var machineIdentifier: Data?
    package var kernelURL = URL(fileURLWithPath: "/fixtures/Image")
    package var initialRamdiskURL: URL?
    package var commandLine = "console=hvc0"
    package var disks: [DiskDefinition] = []
    package var networks: [NetworkDefinition] = []
    package var vsockEnabled = false
    package var consolePorts = [ConsolePortDefinition(role: .systemConsole)]
    package var entropy = true
    package var memoryBalloon = true
    package var sound: SoundDefinition?
    package var customDevices: [any VirtioDeviceModel] = []
    package var builtInDisplay: BuiltInDisplayDefinition?

    package init() {}

    /// Builds the current values into a VM definition.
    package func build() -> VMDefinition {
        VMDefinition(
            label: label,
            cpuCount: cpuCount,
            memorySize: memorySize,
            machineIdentifier: machineIdentifier,
            boot: .linux(
                kernel: kernelURL,
                initialRamdisk: initialRamdiskURL,
                commandLine: commandLine
            ),
            disks: disks,
            networks: networks,
            vsockEnabled: vsockEnabled,
            consolePorts: consolePorts,
            entropy: entropy,
            memoryBalloon: memoryBalloon,
            sound: sound,
            customDevices: customDevices,
            builtInDisplay: builtInDisplay
        )
    }
}
