import Foundation

/// Queue-confined access to a live custom virtio device.
public final class VirtioDeviceContext {
    private let backend: any VirtioDeviceContextBackend
    private let configurationGeneration: UInt64

    package init(backend: any VirtioDeviceContextBackend, generation: UInt64) {
        self.backend = backend
        configurationGeneration = generation
    }

    /// A Sendable handle for configuration updates from asynchronous work.
    ///
    /// Obtain this on the device queue before creating a task. Queue access,
    /// feature inspection, and guest-memory mapping remain confined to the
    /// device queue through this context.
    public var configurationUpdater: VirtioDeviceConfigurationUpdater {
        VirtioDeviceConfigurationUpdater(
            backend: backend,
            generation: configurationGeneration
        )
    }

    /// Returns a device queue after the guest has set `DRIVER_OK`.
    public func queue(_ index: Int) throws(VirtioFailure) -> any VirtioQueue {
        try backend.queue(index, generation: configurationGeneration)
    }

    /// The negotiated feature bits after the guest has set `DRIVER_OK`.
    public var negotiatedFeatures: UInt64 {
        get throws(VirtioFailure) {
            try backend.negotiatedFeatures(generation: configurationGeneration)
        }
    }

    /// Maps and caches a guest physical range until reset or stop.
    public func mapGuestMemory(_ range: GuestPhysicalRange) throws(VirtioFailure) -> GuestMemory {
        try backend.mapGuestMemory(range, generation: configurationGeneration)
    }

    /// Replaces device-specific configuration bytes without changing their size.
    public func updateConfigurationSpace(_ bytes: Data) async throws(VirtioFailure) {
        try await backend.updateConfigurationSpace(bytes, generation: configurationGeneration)
    }

    /// Requests a reset initiated by the host.
    public func requestReset(reason: String) {
        backend.requestReset(reason: reason, generation: configurationGeneration)
    }
}

/// The asynchronous configuration-update capability of a device context.
public struct VirtioDeviceConfigurationUpdater: Sendable {
    private let backend: any VirtioDeviceContextBackend
    private let generation: UInt64

    package init(backend: any VirtioDeviceContextBackend, generation: UInt64) {
        self.backend = backend
        self.generation = generation
    }

    /// Replaces device-specific configuration bytes without changing their size.
    public func updateConfigurationSpace(_ bytes: Data) async throws(VirtioFailure) {
        try await backend.updateConfigurationSpace(bytes, generation: generation)
    }
}

package protocol VirtioDeviceContextBackend: AnyObject, Sendable {
    func queue(_ index: Int, generation: UInt64) throws(VirtioFailure) -> any VirtioQueue
    func negotiatedFeatures(generation: UInt64) throws(VirtioFailure) -> UInt64
    func mapGuestMemory(
        _ range: GuestPhysicalRange,
        generation: UInt64
    ) throws(VirtioFailure) -> GuestMemory
    func updateConfigurationSpace(_ bytes: Data, generation: UInt64) async throws(VirtioFailure)
    func requestReset(reason: String, generation: UInt64)
}
