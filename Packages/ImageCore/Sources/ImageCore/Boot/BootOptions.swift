import Foundation
import VirtualMachineCore

/// The GPU profile of one boot (graphics.md §9).
public enum GPUProfileID: String, Codable, Sendable, CaseIterable {
    /// VirGL through the GraphicsCore virtio-gpu device: the product path.
    case drmVirgl
    /// SwiftShader in the guest over a 2D scanout: Graphics Safe Mode.
    case guestSwiftshader
    /// Development only: SwiftShader over VZ's built-in 2D virtio-gpu, no host window.
    case headless
}

/// What a boot asks of the image (android-image.md §9.1).
public struct BootOptions: Equatable, Sendable {
    /// The loopback TCP port of developer ADB on `127.0.0.1` (configuration.md §2.5). Only developer mode opens it.
    ///
    /// `0` asks the kernel for a free port; the supervisor reports the port it bound. Several VM runs on one
    /// Mac need that, because the default port belongs to one run at a time (test-strategy §3.10). The product
    /// keeps ``defaultADBHostPort``.
    public var adbHostPort: UInt16
    /// The GPU profile whose bootconfig fragment and devices this boot uses.
    public var gpuProfile: GPUProfileID
    /// The Android serial shell on hvc1 and the `androidboot.console` keys (§6.2, §7.1).
    public var developerMode: Bool
    /// Keep the hvc2 logcat stream (§7.1).
    public var captureLogcat: Bool
    /// Whether to attach the host audio output stream.
    public var soundOutput: Bool
    /// Whether to attach the host microphone input stream.
    public var microphone: Bool
    /// `androidboot.lcd_density`: 160 × the backing scale of display 0.
    public var displayDensity: Int

    /// The developer ADB port of the product: `apkrun dev boot` and `apkrun dev adb` use it (configuration.md §2.5).
    public static let defaultADBHostPort: UInt16 = 6520

    /// Creates a value with every field.
    public init(
        gpuProfile: GPUProfileID = .drmVirgl,
        developerMode: Bool = false,
        captureLogcat: Bool = false,
        soundOutput: Bool = false,
        microphone: Bool = false,
        displayDensity: Int = 320,
        adbHostPort: UInt16 = BootOptions.defaultADBHostPort
    ) {
        self.gpuProfile = gpuProfile
        self.developerMode = developerMode
        self.captureLogcat = captureLogcat
        self.soundOutput = soundOutput
        self.microphone = microphone
        self.displayDensity = displayDensity
        self.adbHostPort = adbHostPort
    }
}

/// The Android parts of a boot, ready for RuntimeCore (android-image.md §9.1).
public struct AndroidBootPlan: Sendable {
    /// The VM definition; RuntimeCore adds the GraphicsCore device for every profile except `headless` (#021).
    public var definition: VMDefinition
    /// The merged bootconfig with each key's layer.
    public var bootconfig: [BootconfigEntry]
    /// SHA-256 of the merged bootconfig text, for the boot record.
    public var bootconfigSHA256: String
    /// Identifies this boot in logs and `boots.jsonl`.
    public var bootRecordID: UUID
}
