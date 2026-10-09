import Foundation

/// Host-platform facts that the Android boot needs (android-image.md §5.3, §6.1 layer 3).
///
/// These describe Virtualization.framework, not the image, so they live in
/// ImageCore rather than in a bundle. `Images/reference/vz/<macOS build>/topology.txt`
/// records where each value was observed, and the T2 suite re-checks it on every
/// new macOS build (R-16).
public struct VZPlatformProfile: Equatable, Sendable {
    /// `androidboot.boot_devices`: the platform device of VZ's PCI host bridge.
    public var bootDevices: String

    /// The size of the `headless` profile's built-in 2D scanout (android-image.md §9.1).
    public var headlessDisplay: (widthPixels: Int, heightPixels: Int)

    /// macOS 27.0.1 (26A434): `/sys/block/vda` is under `40000000.pci`.
    public static let macOS27 = VZPlatformProfile(
        bootDevices: "40000000.pci",
        headlessDisplay: (720, 1280)
    )

    /// Compares the boot device and the headless display size.
    public static func == (lhs: VZPlatformProfile, rhs: VZPlatformProfile) -> Bool {
        lhs.bootDevices == rhs.bootDevices && lhs.headlessDisplay == rhs.headlessDisplay
    }
}
