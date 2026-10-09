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

    /// Creates a value with every field.
    public init(
        gpuProfile: GPUProfileID = .drmVirgl,
        developerMode: Bool = false,
        captureLogcat: Bool = false,
        soundOutput: Bool = false,
        microphone: Bool = false,
        displayDensity: Int = 320
    ) {
        self.gpuProfile = gpuProfile
        self.developerMode = developerMode
        self.captureLogcat = captureLogcat
        self.soundOutput = soundOutput
        self.microphone = microphone
        self.displayDensity = displayDensity
    }
}

/// The Android parts of a boot, ready for RuntimeCore (android-image.md §9.1).
public struct AndroidBootPlan: Sendable {
    /// The VM definition; RuntimeCore adds the GraphicsCore device for `drmVirgl`.
    public var definition: VMDefinition
    /// The merged bootconfig with each key's layer.
    public var bootconfig: [BootconfigEntry]
    /// SHA-256 of the merged bootconfig text, for the boot record.
    public var bootconfigSHA256: String
    /// Identifies this boot in logs and `boots.jsonl`.
    public var bootRecordID: UUID
}
