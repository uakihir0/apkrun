import Testing

@testable import RuntimeCore

@Test func gpuChecksAttachTheVirtioGPUDeviceOnlyWhenRequested() throws {
    #expect(try LinuxTestGuestRunner.customDevices(for: ["gpu"]).count == 1)
    #expect(try LinuxTestGuestRunner.customDevices(for: ["gpu-hotplug"]).count == 1)
    #expect(try LinuxTestGuestRunner.customDevices(for: ["rng"]).isEmpty)
    #expect(try LinuxTestGuestRunner.customDevices(for: []).isEmpty)
}
