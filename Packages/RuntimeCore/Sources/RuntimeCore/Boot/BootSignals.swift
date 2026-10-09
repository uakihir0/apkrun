import DiagnosticsCore
import Foundation

/// The console strings that move the boot forward or end it (runtime-daemon.md §3.3).
///
/// The strings were observed on the VZ direct boot of the stock image
/// (android-image.md §7.7). They are data: every pattern lives in this table.
enum BootSignals {
    /// A line pattern that enters a phase.
    struct PhaseSignal: Sendable {
        var phase: BootPhase
        var fragment: String
        var marker: PerfMarker
    }

    /// `.kernel` is entered on the first console byte, not on a line.
    static let kernelMarker = PerfMarker.kernelStart

    /// Later phases, entered on the first line that contains the fragment.
    static let phases: [PhaseSignal] = [
        // hvc0 exists only once first-stage init has loaded virtio_console, so the first
        // init line is "init: Loaded kernel module ..." rather than "first stage started".
        PhaseSignal(phase: .`init`, fragment: "] init: ", marker: .androidInit),
        PhaseSignal(phase: .systemServer, fragment: "init: starting service 'zygote'", marker: .systemServerReady),
        PhaseSignal(phase: .bootCompleted, fragment: "VIRTUAL_DEVICE_BOOT_COMPLETED", marker: .bootCompleted),
    ]

    /// A line that ends the boot with a failure.
    static let kernelPanic = "Kernel panic - not syncing"
    static let androidBootFailed = "VIRTUAL_DEVICE_BOOT_FAILED"
}

/// The Android properties that the ADB readiness signals read (runtime-daemon.md §3.3; development only).
enum AdbBootSignals {
    /// Set once `system_server` has started. A non-empty value enters `.systemServer`.
    static let systemServerStartCount = "sys.system_server.start_count"
    /// `1` once Android reports boot completion. Enters `.bootCompleted`.
    static let bootCompleted = "sys.boot_completed"
}

/// What one poll of the ADB properties saw.
struct AdbBootState: Equatable, Sendable {
    /// Whether `sys.system_server.start_count` is non-empty.
    var systemServerStarted: Bool
    /// Whether `sys.boot_completed` is `1`.
    var bootCompleted: Bool
}
