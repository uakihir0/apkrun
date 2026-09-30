import Foundation
import Testing
import VirtualMachineCoreTestSupport

@testable import VirtualMachineCore

@Test
func linuxTestGuestBuildsTheDocumentedMinimalDefinition() {
    let definition = LinuxTestGuest.definition(
        kernel: URL(fileURLWithPath: "/fixtures/Image"),
        initrd: URL(fileURLWithPath: "/fixtures/initramfs.cpio.gz"),
        tests: ["blk", "ports"],
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
            == "console=hvc0 apkrun.test=blk,ports apkrun.test.poweroff=1 loglevel=7"
    )
    #expect(definition.disks.isEmpty)
    #expect(definition.network == nil)
    #expect(!definition.vsockEnabled)
    #expect(definition.consolePorts == [ConsolePortDefinition(role: .systemConsole)])
    #expect(definition.entropy)
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
