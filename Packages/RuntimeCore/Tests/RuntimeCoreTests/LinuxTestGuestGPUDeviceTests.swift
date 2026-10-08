import Testing

@testable import RuntimeCore

@Test func gpuChecksAttachTheVirtioGPUDeviceOnlyWhenRequested() {
    #expect(LinuxTestGuestRunner.customDevices(for: ["gpu"]).count == 1)
    #expect(LinuxTestGuestRunner.customDevices(for: ["gpu-hotplug"]).count == 1)
    #expect(LinuxTestGuestRunner.customDevices(for: ["rng"]).isEmpty)
    #expect(LinuxTestGuestRunner.customDevices(for: []).isEmpty)
}
