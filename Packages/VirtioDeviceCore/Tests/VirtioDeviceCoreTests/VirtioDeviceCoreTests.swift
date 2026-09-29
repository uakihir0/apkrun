import Foundation
import Testing

@testable import VirtioDeviceCore

@Test func descriptorPreservesConfigurationAndSharedMemoryMetadata() {
    let descriptor = VirtioDeviceDescriptor(
        name: "test-entropy",
        deviceID: 4,
        pciClass: 0x10,
        pciSubclass: 0,
        queueCount: 1,
        mandatoryFeatures: 1 << 32,
        optionalFeatures: 1 << 2,
        configurationSpace: Data([0xAA, 0x55]),
        sharedMemoryRegions: [
            SharedMemoryRegionDescriptor(regionID: 3, sizeBytes: 8_192)
        ]
    )

    #expect(descriptor.name == "test-entropy")
    #expect(descriptor.deviceID == 4)
    #expect(descriptor.queueCount == 1)
    #expect(descriptor.mandatoryFeatures == 1 << 32)
    #expect(descriptor.optionalFeatures == 1 << 2)
    #expect(descriptor.configurationSpace == Data([0xAA, 0x55]))
    #expect(
        descriptor.sharedMemoryRegions == [
            SharedMemoryRegionDescriptor(regionID: 3, sizeBytes: 8_192)
        ])
}
