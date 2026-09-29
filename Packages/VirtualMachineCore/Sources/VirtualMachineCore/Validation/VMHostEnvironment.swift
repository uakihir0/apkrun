import Foundation

/// Host facts consumed by VM definition validation.
package protocol VMHostEnvironment: Sendable {
    var activeProcessorCount: Int { get }
    var physicalMemoryBytes: UInt64 { get }
    var minimumAllowedCPUCount: Int { get }
    var maximumAllowedCPUCount: Int { get }
    var minimumAllowedMemorySize: UInt64 { get }
    var maximumAllowedMemorySize: UInt64 { get }
    var microphoneUsageDescription: String? { get }

    func probeFile(at url: URL) -> VMFileProbe
}
