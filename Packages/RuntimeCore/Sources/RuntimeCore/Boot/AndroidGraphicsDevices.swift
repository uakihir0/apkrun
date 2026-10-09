import GraphicsCore
import ImageCore

/// The virtio-gpu device that an Android boot profile needs (graphics.md §9, #021).
///
/// ImageCore cannot depend on GraphicsCore, so the planner leaves `customDevices` empty and
/// RuntimeCore appends the device for the requested profile (android-image.md §9.2). The profile's
/// `requiredHostCapabilities` come from the bundle manifest, and the device must offer each of them
/// (runtime-image-manifest.md §4.7). A profile the device cannot satisfy is refused before the VM
/// starts, because the guest would stall without its DRM device or its VirGL features.
enum AndroidGraphicsDevices {
    /// The devices that `profile` adds to the boot plan.
    ///
    /// - Parameters:
    ///   - profile: The GPU profile of the boot.
    ///   - requiredHostCapabilities: The profile's entry in the bundle manifest, or `nil` when the bundle does not
    ///     list the profile.
    /// - Returns: No device for `headless`, because VZ's own 2D device provides the DRM device there (graphics.md
    ///   §9). For the other profiles, one virtio-gpu device, which offers EDID only until the renderer lands (#022).
    static func devices(
        for profile: GPUProfileID,
        requiredHostCapabilities: [String]?
    ) throws(RuntimeBootFailure) -> [VirtioGPUDevice] {
        guard profile != .headless else {
            return []
        }
        let device = VirtioGPUDevice()
        guard let required = requiredHostCapabilities,
            Set(required).isSubset(of: device.hostCapabilities)
        else {
            throw .gpuProfileUnavailable(profile: profile.rawValue)
        }
        return [device]
    }
}
