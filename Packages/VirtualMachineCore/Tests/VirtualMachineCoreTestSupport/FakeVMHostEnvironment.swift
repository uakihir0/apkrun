import Foundation
import VirtualMachineCore

/// Deterministic host facts for VM validation tests.
package struct FakeVMHostEnvironment: VMHostEnvironment {
    package let activeProcessorCount: Int
    package let physicalMemoryBytes: UInt64
    package let minimumAllowedCPUCount: Int
    package let maximumAllowedCPUCount: Int
    package let minimumAllowedMemorySize: UInt64
    package let maximumAllowedMemorySize: UInt64
    package let microphoneUsageDescription: String?
    private let fileProbes: [URL: VMFileProbeFixture]

    package init(
        activeProcessorCount: Int = 8,
        physicalMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024,
        minimumAllowedCPUCount: Int = 2,
        maximumAllowedCPUCount: Int = 8,
        minimumAllowedMemorySize: UInt64 = 1 * 1_024 * 1_024 * 1_024,
        maximumAllowedMemorySize: UInt64 = 64 * 1_024 * 1_024 * 1_024,
        microphoneUsageDescription: String? = nil,
        fileProbes: [URL: VMFileProbeFixture] = [:]
    ) {
        self.activeProcessorCount = activeProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
        self.minimumAllowedCPUCount = minimumAllowedCPUCount
        self.maximumAllowedCPUCount = maximumAllowedCPUCount
        self.minimumAllowedMemorySize = minimumAllowedMemorySize
        self.maximumAllowedMemorySize = maximumAllowedMemorySize
        self.microphoneUsageDescription = microphoneUsageDescription
        self.fileProbes = Dictionary(
            uniqueKeysWithValues: fileProbes.map { ($0.key.standardizedFileURL, $0.value) }
        )
    }

    package func probeFile(at url: URL) -> VMFileProbe {
        let fixture = fileProbes[url.standardizedFileURL] ?? .missing
        return VMFileProbe(
            exists: fixture.exists,
            isRegularFile: fixture.isRegularFile,
            sizeBytes: fixture.sizeBytes,
            first64Bytes: fixture.first64Bytes,
            isReadable: fixture.isReadable,
            isWritable: fixture.isWritable,
            resolvedFileURL: fixture.resolvedFileURL
                ?? (fixture.exists && fixture.isRegularFile
                    ? url.standardizedFileURL
                    : nil)
        )
    }
}

/// File facts returned by `FakeVMHostEnvironment`.
package struct VMFileProbeFixture: Equatable, Sendable {
    package let exists: Bool
    package let isRegularFile: Bool
    package let sizeBytes: UInt64?
    package let first64Bytes: Data
    package let isReadable: Bool
    package let isWritable: Bool
    package let resolvedFileURL: URL?

    package init(
        exists: Bool = true,
        isRegularFile: Bool = true,
        sizeBytes: UInt64? = 64,
        first64Bytes: Data = Data(),
        isReadable: Bool = true,
        isWritable: Bool = true,
        resolvedFileURL: URL? = nil
    ) {
        self.exists = exists
        self.isRegularFile = isRegularFile
        self.sizeBytes = sizeBytes
        self.first64Bytes = first64Bytes
        self.isReadable = isReadable
        self.isWritable = isWritable
        self.resolvedFileURL = resolvedFileURL
    }

    package static let missing = VMFileProbeFixture(
        exists: false,
        isRegularFile: false,
        sizeBytes: nil,
        isReadable: false,
        isWritable: false
    )
}
