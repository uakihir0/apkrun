import GraphicsCore
import ImageCore

/// The virtio-gpu device that an Android boot profile needs (graphics.md §9, #021, #022).
///
/// ImageCore cannot depend on GraphicsCore, so the planner leaves `customDevices` empty and
/// RuntimeCore appends the device for the requested profile (android-image.md §9.2). The profile's
/// `requiredHostCapabilities` come from the bundle manifest, and the device must offer each of them
/// (runtime-image-manifest.md §4.7). A profile the bundle does not list, or a device that lacks a required
/// feature, is refused before the VM starts, because the guest would stall without its DRM device or its
/// VirGL features.
enum AndroidGraphicsDevices {
    /// The devices that `profile` adds to the boot plan.
    ///
    /// - Parameters:
    ///   - profile: The GPU profile of the boot.
    ///   - requiredHostCapabilities: The profile's entry in the bundle manifest, or `nil` when the bundle does not
    ///     list the profile.
    /// - Returns: No device for `headless`, because VZ's own 2D device provides the DRM device there (graphics.md
    ///   §9). `guestSwiftshader` gets the two-dimensional device, which offers EDID and host-memory 2D resources.
    ///   `drmVirgl` gets the VirGL device, which starts the renderer now, before the instance is read (graphics.md §8).
    static func devices(
        for profile: GPUProfileID,
        requiredHostCapabilities: [String]?
    ) throws(RuntimeBootFailure) -> [VirtioGPUDevice] {
        try devices(for: profile, requiredHostCapabilities: requiredHostCapabilities) {
            () throws(GraphicsFailure) in try VirtioGPUDevice.virgl()
        }
    }

    /// The devices that `profile` adds to the boot plan, with the VirGL device made by `makeVirglDevice`.
    ///
    /// The production path passes `VirtioGPUDevice.virgl`. Tests pass a factory to fail the renderer, or to count
    /// the renderers that a boot starts.
    static func devices(
        for profile: GPUProfileID,
        requiredHostCapabilities: [String]?,
        makeVirglDevice: () throws(GraphicsFailure) -> VirtioGPUDevice
    ) throws(RuntimeBootFailure) -> [VirtioGPUDevice] {
        guard profile != .headless else {
            return []
        }
        // The bundle must list the profile before a device is made, so an unlisted profile starts no renderer.
        guard let required = requiredHostCapabilities else {
            throw .gpuProfileUnavailable(profile: profile.rawValue)
        }
        let device = try makeDevice(for: profile, makeVirglDevice: makeVirglDevice)
        guard Set(required).isSubset(of: device.hostCapabilities) else {
            throw .gpuProfileUnavailable(profile: profile.rawValue)
        }
        return [device]
    }

    /// The device of a profile that has one. A renderer failure is reported as ``RuntimeBootFailure/graphics(_:)``.
    private static func makeDevice(
        for profile: GPUProfileID,
        makeVirglDevice: () throws(GraphicsFailure) -> VirtioGPUDevice
    ) throws(RuntimeBootFailure) -> VirtioGPUDevice {
        switch profile {
        case .guestSwiftshader:
            return VirtioGPUDevice.twoDimensional()
        case .drmVirgl:
            do throws(GraphicsFailure) {
                return try makeVirglDevice()
            } catch {
                throw .graphics(error)
            }
        case .headless:
            // `devices(for:requiredHostCapabilities:makeVirglDevice:)` returns before this point for `headless`.
            throw .gpuProfileUnavailable(profile: profile.rawValue)
        }
    }
}
