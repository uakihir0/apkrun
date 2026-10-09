import DiagnosticsCore
import Foundation
import ImageCore
import VirtualMachineCore

/// Why an Android boot failed (error domain `runtime`; error-catalog.md §7.2).
///
/// The first cut of the supervisor's failures (#012-#014). RuntimeHost's
/// `RuntimeFailure` holds the host-process cases of the same domain; the two
/// merge when the full `RuntimeSupervisor` arrives (IR-312).
public enum RuntimeBootFailure: APKRunError, Equatable {
    /// ImageCore failed in the pre-boot checks or while writing the initrd.
    case image(ImageFailure)
    /// `VMDefinitionValidator` rejected the definition.
    case vmConfiguration(VMConfigurationFailure)
    /// The VM failed to start or failed while booting.
    case vm(VMFailure)
    /// The console showed `Kernel panic - not syncing`.
    case kernelPanic
    /// The console showed `VIRTUAL_DEVICE_BOOT_FAILED`, or the guest stopped while booting.
    case androidBootFailed(detail: String)
    /// The whole boot exceeded its timeout.
    case bootTimedOut(phase: BootPhase)
    /// No phase progress within the stall limit.
    case bootStalled(phase: BootPhase)
    /// The boot profile needs a virtio-gpu feature that the device does not offer (graphics.md §9, #021).
    case gpuProfileUnavailable(profile: String)
    /// The development Guest Agent could not be installed, started, or reached (guest-components.md §3).
    case guestAgent(GuestAgentFailure)

    /// The `runtime` error domain.
    public static let domain: ErrorDomain = .runtime

    /// The catalog code.
    public var code: String {
        switch self {
        case .image: "image"
        case .vmConfiguration: "vmConfiguration"
        case .vm: "vm"
        case .kernelPanic: "kernelPanic"
        case .androidBootFailed: "androidBootFailed"
        case .bootTimedOut: "bootTimedOut"
        case .bootStalled: "bootStalled"
        case .gpuProfileUnavailable: "gpuProfileUnavailable"
        case .guestAgent: "guestAgent"
        }
    }

    /// The catalog parameters.
    public var parameters: [String: ErrorParameter] {
        switch self {
        case .androidBootFailed(let detail): ["detail": .text(detail)]
        case .bootTimedOut(let phase), .bootStalled(let phase): ["phase": .text(phase.description)]
        case .gpuProfileUnavailable(let profile): ["profile": .text(profile)]
        default: [:]
        }
    }

    /// The ImageCore or VirtualMachineCore failure behind a transparent case.
    public var cause: (any APKRunError)? {
        switch self {
        case .image(let failure): failure
        case .vmConfiguration(let failure): failure
        case .vm(let failure): failure
        case .guestAgent(let failure): failure
        default: nil
        }
    }
}
