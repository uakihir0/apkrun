import Foundation
import VirtioDeviceCore

/// Builds the small ARM64 guest used by the M0 VM integration tests.
public enum LinuxTestGuest {
    /// Creates the task's two-vCPU, one-GiB Linux test guest definition.
    public static func definition(
        kernel: URL,
        initrd: URL,
        tests: [String] = [],
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
        let commandLine =
            ([
                "console=hvc0",
                "apkrun.test=\(checks)",
                "apkrun.test.poweroff=\(powerOff ? 1 : 0)",
            ] + (usesEntropyDevice ? ["rng_core.default_quality=0"] : []) + extraCommandLine)
            .joined(separator: " ")

        return VMDefinition(
            label: "APKRun Linux test guest",
            cpuCount: 2,
            memorySize: 1 * 1_024 * 1_024 * 1_024,
            boot: .linux(
                kernel: kernel,
                initialRamdisk: initrd,
                commandLine: commandLine
            ),
            disks: [],
            network: nil,
            vsockEnabled: false,
            consolePorts: [ConsolePortDefinition(role: .systemConsole)],
            entropy: !usesEntropyDevice,
            customDevices: customDevices + (entropyDevice.map { [$0 as any VirtioDeviceModel] } ?? [])
        )
    }
}
