import Foundation
import Testing
import VirtualMachineCoreTestSupport

@testable import VirtualMachineCore

@Test func machineIdentityValuesSurviveCodableAndGeneratedMACsPassValidation() throws {
    let machineIdentifier = MachineIdentity.newMachineIdentifier()
    let macAddress = MachineIdentity.newMACAddress()
    let value = IdentityFixture(machineIdentifier: machineIdentifier, macAddress: macAddress)
    let encoded = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(IdentityFixture.self, from: encoded)
    #expect(decoded == value)

    let builder = VMDefinitionBuilder()
    let validator = VMDefinitionValidator(
        host: FakeVMHostEnvironment(
            fileProbes: [
                builder.kernelURL: VMFileProbeFixture(
                    sizeBytes: 64,
                    first64Bytes: arm64KernelHeader
                )
            ]
        ),
        frameworkValidator: FakeFrameworkConfigurationValidator()
    )
    for _ in 0..<1_000 {
        var definition = builder.build()
        definition.network = .nat(macAddress: MachineIdentity.newMACAddress())
        #expect(validator.findings(definition).isEmpty)
    }
}

private struct IdentityFixture: Codable, Equatable {
    let machineIdentifier: Data
    let macAddress: String
}

private let arm64KernelHeader: Data = {
    var bytes = Data(repeating: 0, count: 64)
    bytes.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
    return bytes
}()
