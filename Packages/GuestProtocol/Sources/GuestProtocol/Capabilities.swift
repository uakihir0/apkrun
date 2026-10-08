/// The capabilities of guest-protocol.md §5.3.
///
/// A capability string has the form `<area>.<feature>.v<n>`. The agent lists what it implements,
/// and the host enables the subset it uses. Both sides reject requests for capabilities that
/// are not enabled.
public enum GuestCapability: String, CaseIterable, Sendable {
    case core = "core.v1"
    case display = "display.v1"
    case launch = "launch.v1"
    case input = "input.v1"
    case ime = "ime.v1"
    case packages = "packages.v1"
    case health = "health.v1"
    case system = "system.v1"
    case clipboardText = "clipboard.text.v1"
    case clipboardImage = "clipboard.image.v1"
    case notifications = "notifications.v1"
    case url = "url.v1"
    case files = "files.v1"
    case filesShared = "files.shared.v1"
    case locale = "locale.v1"
    case audio = "audio.v1"
    case diagnostics = "diagnostics.v1"
    case bulk = "bulk.v1"
    case storeInstall = "store.install.v1"
    case storeMetadata = "store.metadata.v1"
    case storeIcon = "store.icon.v1"
    case storeRollback = "store.rollback.v1"
    case storeOwnership = "store.ownership.v1"
    case storeConstraints = "store.constraints.v1"
}

/// Negotiates the capabilities of one connection (guest-protocol.md §5.3).
public enum CapabilityNegotiation {
    /// The capabilities that the host enables: the ones that the agent advertised and that the
    /// host supports. Unknown strings are ignored, so an agent that advertises a newer capability
    /// does not break the handshake. The result is sorted and has no duplicates.
    public static func enabled(
        advertised: [String],
        supported: Set<GuestCapability> = Set(GuestCapability.allCases)
    ) -> [String] {
        let supportedNames = Set(supported.map(\.rawValue))
        return Array(Set(advertised).intersection(supportedNames)).sorted()
    }
}
