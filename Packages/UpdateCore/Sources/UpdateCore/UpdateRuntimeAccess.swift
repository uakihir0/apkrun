import APKStoreCore
import Foundation
import RuntimeAPI

/// The runtime surface an update install needs (update-system.md §7.5).
/// RuntimeHost injects the implementation; UpdateCore never imports
/// RuntimeCore. #39 uses only the members an install gate requires — the
/// session, display, and health-launch surface lands in #40.
public protocol UpdateRuntimeAccess: Sendable {
    /// Android's state as the runtime reports it.
    var runtimeState: WireRuntimeState { get async }
    /// GU2 + GU3: the package has an open session or is otherwise in use;
    /// the install must stay staged.
    func hasActiveUse(_ package: PackageID) async -> Bool
    /// Brings the runtime up for an update (`StartReason` `.update`, §3.5,
    /// §7.3). Automatic runs need a ready runtime.
    func ensureReadyForUpdate() async throws
}
