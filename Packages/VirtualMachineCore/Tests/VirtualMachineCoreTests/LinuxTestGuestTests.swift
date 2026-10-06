import Foundation
import Testing
import VirtioDeviceCore
import VirtualMachineCoreTestSupport

@testable import VirtualMachineCore

@Test
func linuxTestGuestBuildsTheDocumentedMinimalDefinition() {
    let definition = LinuxTestGuest.definition(
        kernel: URL(fileURLWithPath: "/fixtures/Image"),
        initrd: URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz"),
        tests: ["ports"],
        powerOff: true,
        extraCommandLine: ["loglevel=7"]
    )

    #expect(definition.label == "APKRun Linux test guest")
    #expect(definition.cpuCount == 2)
    #expect(definition.memorySize == 1 * 1_024 * 1_024 * 1_024)
    let boot = definition.bootKernelConfigurationForTesting
    #expect(boot.0 == URL(fileURLWithPath: "/fixtures/Image"))
    #expect(boot.1 == URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz"))
    #expect(
        boot.2
            == "console=hvc0 apkrun.test=ports apkrun.test.poweroff=1 loglevel=7"
    )
    #expect(definition.disks.isEmpty)
    #expect(definition.network == nil)
    #expect(!definition.vsockEnabled)
    #expect(
        definition.consolePorts
            == [
                ConsolePortDefinition(role: .systemConsole),
                ConsolePortDefinition(role: .service(name: "test-1")),
                ConsolePortDefinition(role: .service(name: "test-2")),
            ]
    )
    #expect(definition.entropy)
}

@Test
func linuxTestGuestAddsNATOnlyForTheNetworkCheck() {
    let definition = LinuxTestGuest.definition(
        kernel: URL(fileURLWithPath: "/fixtures/Image"),
        initrd: URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz"),
        tests: ["net"],
        powerOff: true,
        extraCommandLine: ["apkrun.test.net.port=43210"]
    )

    guard case .nat(let macAddress)? = definition.network else {
        Issue.record("the net check must attach a NAT network")
        return
    }

    let octets = macAddress.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    #expect(octets.count == 6)
    #expect(octets.first.map { ($0 & 0b10) != 0 } == true)
    #expect(octets.first.map { ($0 & 0b01) == 0 } == true)
    #expect(
        definition.bootKernelConfigurationForTesting.2.contains(
            "apkrun.test.net.port=43210"
        )
    )
}

@Test
func linuxTestGuestEnablesVsockOnlyForTheVsockCheck() {
    let kernel = URL(fileURLWithPath: "/fixtures/Image")
    let initrd = URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz")

    let withoutVsock = LinuxTestGuest.definition(
        kernel: kernel,
        initrd: initrd,
        tests: ["ports"]
    )
    let withVsock = LinuxTestGuest.definition(
        kernel: kernel,
        initrd: initrd,
        tests: ["vsock"]
    )

    #expect(!withoutVsock.vsockEnabled)
    #expect(withVsock.vsockEnabled)
}

@Test
func linuxTestGuestReplacesBuiltInEntropyForTheRNGCheck() {
    let device = EntropyTestDevice(seed: 42, performsConfigurationProbe: false)
    let definition = LinuxTestGuest.definition(
        kernel: URL(fileURLWithPath: "/fixtures/Image"),
        initrd: URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz"),
        tests: ["rng"],
        entropyTestDevice: device,
        powerOff: true,
        extraCommandLine: ["loglevel=7"]
    )

    let boot = definition.bootKernelConfigurationForTesting
    #expect(
        boot.2
            == "console=hvc0 apkrun.test=rng apkrun.test.poweroff=1 rng_core.default_quality=0 loglevel=7"
    )
    #expect(!definition.entropy)
    #expect(definition.customDevices.count == 1)
    #expect(definition.customDevices[0].descriptor.deviceID == 4)
    #expect(definition.customDevices[0].descriptor.configurationSpace.count == 8)
}

@Test
func linuxTestGuestUsesTheCustomEntropyDeviceForPendingElementProbe() {
    let device = EntropyTestDevice(seed: 42, performsConfigurationProbe: false)
    let definition = LinuxTestGuest.definition(
        kernel: URL(fileURLWithPath: "/fixtures/Image"),
        initrd: URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz"),
        tests: ["rng-pending"],
        entropyTestDevice: device,
        powerOff: false
    )

    let boot = definition.bootKernelConfigurationForTesting
    #expect(boot.2.contains("apkrun.test=rng-pending"))
    #expect(boot.2.contains("rng_core.default_quality=0"))
    #expect(!definition.entropy)
    #expect(definition.customDevices.count == 1)
    #expect(definition.customDevices[0].descriptor.deviceID == 4)
}

@Test
func linuxTestGuestAttachesBlockDisksByIdentifierInRequestedOrder() {
    let disks = LinuxTestGuest.BlockDisks(
        readOnly: URL(fileURLWithPath: "/fixtures/ro.img"),
        readWrite: URL(fileURLWithPath: "/fixtures/rw.img")
    )
    let firstDefinition = LinuxTestGuest.definition(
        kernel: URL(fileURLWithPath: "/fixtures/Image"),
        initrd: URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz"),
        tests: ["blk"],
        blockDisks: disks
    )
    let reversedDefinition = LinuxTestGuest.definition(
        kernel: URL(fileURLWithPath: "/fixtures/Image"),
        initrd: URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz"),
        tests: ["blk"],
        blockDisks: disks,
        blockDiskOrder: .readWriteThenReadOnly
    )

    #expect(firstDefinition.disks.map(\.identifier) == ["apkrun-ro", "apkrun-rw"])
    #expect(firstDefinition.disks.map(\.readOnly) == [true, false])
    #expect(firstDefinition.disks.map(\.url) == [disks.readOnly, disks.readWrite])
    #expect(reversedDefinition.disks.map(\.identifier) == ["apkrun-rw", "apkrun-ro"])
    #expect(reversedDefinition.disks.map(\.readOnly) == [false, true])
}

@Test
func linuxTestGuestDefinitionPassesVMDefinitionValidation() throws {
    let kernel = URL(fileURLWithPath: "/fixtures/Image")
    let initrd = URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz")
    var header = Data(repeating: 0, count: 64)
    header.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
    let host = FakeVMHostEnvironment(
        fileProbes: [
            kernel: VMFileProbeFixture(sizeBytes: 64, first64Bytes: header),
            initrd: VMFileProbeFixture(sizeBytes: 4_096),
        ]
    )
    let validator = VMDefinitionValidator(
        host: host,
        frameworkValidator: FakeFrameworkConfigurationValidator()
    )
    let definition = LinuxTestGuest.definition(kernel: kernel, initrd: initrd)

    #expect(try validator.validate(definition).definition.summary.cpuCount == 2)
}

extension VMDefinition {
    fileprivate var bootKernelConfigurationForTesting: (URL, URL?, String) {
        guard case .linux(let kernel, let initrd, let commandLine) = boot else {
            preconditionFailure("LinuxTestGuest must use the Linux boot loader.")
        }
        return (kernel, initrd, commandLine)
    }
}
